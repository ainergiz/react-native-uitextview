# UITextView Custom Menu Plan

date: 2025-11-03

This document tracks the work required to support configurable context-menu actions (e.g., "Highlight") when selecting text inside `react-native-uitextview`.

## Goals

- Allow JavaScript to declare custom menu items for iOS `UITextView` instances rendered by this library.
- Emit selection metadata back to JS when a custom menu action fires so the app can highlight, annotate, etc.
- Maintain compatibility with default copy/selection actions unless the host opts into replacing them.

## Plan & Tasks

- [x] Extend the generated component props with:
  - `menuItems?: { id: string; title: string }[]`
  - `menuBehavior?: 'augment' | 'replace'`
  - `onMenuAction?: (event: { id: string; selectedText: string; range: { start: number; end: number } }) => void`
- [x] Regenerate codegen artifacts (`yarn prepare` / `bob build`).
- [x] Implement menu handling in `RNUITextView.mm`:
  - Cache menu configuration and active selection range.
  - Override menu-building APIs for iOS 13+.
  - Emit `onMenuAction` events with selection payload.
- [x] Wire JS `<UITextView>` wrapper to forward new props.
- [x] Update example app / debug screen to demo a custom "Highlight" action.
- [ ] Add tests:
  - JS unit test to assert prop types & default behavior.
  - Native integration test (Xcode/ui-testing or manual checklist) verifying menu actions appear and emit.
- [ ] Update README with usage docs.

## Notes

- Initial implementation targets iOS; Android still falls back to RN `<Text>`.
- When replacing system actions, ensure accessibility hints are preserved.
- Keep selection ranges in UTF-16 to align with existing RN conventions.
