# ESPDeck site

`index.html` is the project's home page, with its pictures in `images/` (copies of the ones in `docs/images`). `install/index.html` is the web installer: it installs the firmware from the browser with [ESP Web Tools](https://github.com/esphome/esp-web-tools) (Chrome or Edge on a desktop). `manifest.json` points at `firmware/espdeck-firmware-VERSION-merged.bin`, the full flash image written at offset 0.

The image has to be served from the same site as the page: ESP Web Tools downloads it with `fetch`, and GitHub release assets don't allow cross-origin requests. `ESPDeck Device/tools/release.sh VERSION` copies the merged image into `firmware/` and rewrites `manifest.json` for that version.

## Publishing with GitHub Pages

Automatic, two ways. `.github/workflows/pages.yml` deploys this folder whenever something in it changes on `main`, after fetching the firmware image that `manifest.json` names from its release. `.github/workflows/firmware.yml` runs on every `firmware-v*` tag: it builds the release, attaches the images to the GitHub release, and deploys this folder too. Set **Settings → Pages → Source** to **GitHub Actions** once.

By hand:
1. Run `ESPDeck Device/tools/release.sh X.Y.Z`.
2. Publish this folder, including `firmware/`, with Pages. Either commit it and choose **Deploy from a branch**, or upload it with the `actions/upload-pages-artifact` and `actions/deploy-pages` actions.

Pages serves over HTTPS, which Web Serial requires. To try the page locally, serve this folder from `localhost` (for example `python3 -m http.server` in `web/`); opening `index.html` as a file won't work.
