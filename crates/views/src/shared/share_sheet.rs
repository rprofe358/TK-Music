use gpui::prelude::*;
use gpui::{
    App, ClipboardItem, Context, Entity, FocusHandle, Global, Render, SharedString, Window, div,
};
use i18n::t;
use music::MediaKind;
use state::{Outcome, Toasts};
use ui::{ActiveTheme as _, Artwork, Button, Dismiss, FORM_CONTEXT, Modal, PinKind};

/// What the share sheet presents and copies or opens for the listener.
#[derive(Clone)]
pub(crate) struct ShareTarget {
    pub title: String,
    pub subtitle: String,
    pub cover: Option<String>,
    pub url: String,
    pub kind: MediaKind,
}

/// A desktop share sheet modal showing a preview of a track, album, playlist, or artist with
/// one-click actions to copy the link, copy formatted text, or open in the browser.
pub(crate) struct ShareSheet {
    target: Option<ShareTarget>,
    focus: FocusHandle,
    restore: Option<FocusHandle>,
}

struct Installed(Entity<ShareSheet>);

impl Global for Installed {}

impl ShareSheet {
    pub fn entity(cx: &mut App) -> Entity<Self> {
        if cx.try_global::<Installed>().is_none() {
            let sheet = cx.new(|cx| Self {
                target: None,
                focus: cx.focus_handle(),
                restore: None,
            });
            cx.set_global(Installed(sheet));
        }
        cx.global::<Installed>().0.clone()
    }

    pub fn open(target: ShareTarget, window: &mut Window, cx: &mut App) {
        let sheet = Self::entity(cx);
        sheet.update(cx, |this, cx| this.show(target, window, cx));
    }

    fn show(&mut self, target: ShareTarget, window: &mut Window, cx: &mut Context<Self>) {
        self.restore = window.focused(cx);
        self.target = Some(target);
        window.focus(&self.focus, cx);
        cx.notify();
    }

    fn close(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.target = None;
        if let Some(focus) = self.restore.take() {
            window.focus(&focus, cx);
        }
        cx.notify();
    }

    fn copy_link(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(target) = self.target.clone() else {
            return;
        };
        cx.write_to_clipboard(ClipboardItem::new_string(target.url));
        Toasts::show(Outcome::Done, "toast-link-copied", cx);
        self.close(window, cx);
    }

    fn copy_text(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(target) = self.target.clone() else {
            return;
        };
        let text = match target.subtitle.is_empty() {
            true => format!("{}\n{}", target.title, target.url),
            false => format!("{} — {}\n{}", target.title, target.subtitle, target.url),
        };
        cx.write_to_clipboard(ClipboardItem::new_string(text));
        Toasts::show(Outcome::Done, "toast-share-copied", cx);
        self.close(window, cx);
    }

    fn open_browser(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(target) = self.target.clone() else {
            return;
        };
        cx.open_url(&target.url);
        self.close(window, cx);
    }
}

impl Render for ShareSheet {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let Some(target) = self.target.clone() else {
            return div().into_any_element();
        };
        let theme = *cx.theme();
        let metrics = theme.metrics;
        let round = target.kind == MediaKind::Artist;
        let fallback = match target.kind {
            MediaKind::Artist => PinKind::Artist.icon(),
            MediaKind::Album => PinKind::Album.icon(),
            MediaKind::Playlist => PinKind::Playlist.icon(),
            MediaKind::Track => PinKind::Album.icon(),
        };
        let thumb = metrics.cover * 0.42;

        let preview = div()
            .flex()
            .items_center()
            .gap(metrics.pad)
            .p(metrics.pad * 0.75)
            .rounded(theme.radius)
            .bg(theme.muted)
            .child(
                Artwork::new(target.cover)
                    .size(thumb)
                    .corner_radius(theme.radius)
                    .fallback(fallback)
                    .when(round, Artwork::circle)
                    .flex_none(),
            )
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .flex()
                    .flex_col()
                    .gap_1()
                    .child(
                        div()
                            .text_sm()
                            .font_weight(gpui::FontWeight::SEMIBOLD)
                            .text_color(theme.foreground)
                            .truncate()
                            .child(SharedString::from(target.title)),
                    )
                    .when(!target.subtitle.is_empty(), |el| {
                        el.child(
                            div()
                                .text_xs()
                                .text_color(theme.muted_foreground)
                                .truncate()
                                .child(SharedString::from(target.subtitle)),
                        )
                    })
                    .child(
                        div()
                            .text_xs()
                            .text_color(theme.muted_foreground)
                            .truncate()
                            .child(SharedString::from(target.url)),
                    ),
            );

        let buttons = div()
            .flex()
            .flex_col()
            .gap_2()
            .child(
                Button::new("share-copy-link")
                    .primary()
                    .w_full()
                    .icon("icons/link.svg")
                    .label(t!("share-copy-link"))
                    .on_click(cx.listener(|this, _, window, cx| this.copy_link(window, cx))),
            )
            .child(
                Button::new("share-copy-text")
                    .outline()
                    .w_full()
                    .icon("icons/copy.svg")
                    .label(t!("share-copy-text"))
                    .on_click(cx.listener(|this, _, window, cx| this.copy_text(window, cx))),
            )
            .child(
                Button::new("share-open-browser")
                    .ghost()
                    .w_full()
                    .icon("icons/external-link.svg")
                    .label(t!("share-open-browser"))
                    .on_click(cx.listener(|this, _, window, cx| this.open_browser(window, cx))),
            );

        div()
            .absolute()
            .inset_0()
            .key_context(FORM_CONTEXT)
            .track_focus(&self.focus)
            .on_action(cx.listener(|this, _: &Dismiss, window, cx| {
                cx.stop_propagation();
                this.close(window, cx);
            }))
            .child(
                Modal::new("share-sheet", t!("share-sheet-title"))
                    .w(metrics.cover * 2.8)
                    .child(
                        div()
                            .flex()
                            .flex_col()
                            .gap(metrics.pad)
                            .child(preview)
                            .child(buttons),
                    )
                    .action(
                        Button::new("close-share-sheet")
                            .ghost()
                            .label(t!("common-close"))
                            .on_click(cx.listener(|this, _, window, cx| this.close(window, cx))),
                    )
                    .on_dismiss(cx.listener(|this, _, window, cx| this.close(window, cx))),
            )
            .into_any_element()
    }
}
