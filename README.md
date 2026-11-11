# Stack launch page

The promo page for the new Stack widget home. It's a static site served by GitHub Pages.

- `index.html`, `styles.css`, `app.js`: the page
- `shots/`: 1179×2556 (393×852 @3x) captures of the live preview (`/stack/preview-widget/`), which only ever uses made-up sample data
- `icon.svg`, `icon-*.png`, `og.png`: the app icon and share image

## Native Apple application

The iOS 17 SwiftUI implementation lives in [`native/`](native/README.md). Open `native/Stack.xcodeproj` on a Mac. The original promotional website above is preserved.

See [repository assessment](docs/REPOSITORY-ASSESSMENT.md) for recovered code and BMO/Plaid findings, and [optional ingestion job](backend/README.md) for backend setup and limitations.
