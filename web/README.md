# ESPDeck web installer

`index.html` installs the firmware from the browser with [ESP Web Tools](https://github.com/esphome/esp-web-tools) (Chrome or Edge on a desktop). `manifest.json` points at `firmware/espdeck-firmware-VERSION-merged.bin`, the full flash image written at offset 0.

The image has to be served from the same site as the page: ESP Web Tools downloads it with `fetch`, and GitHub release assets don't allow cross-origin requests. `ESPDeck Device/tools/release.sh VERSION` copies the merged image into `firmware/` and rewrites `manifest.json` for that version.

## Publishing with GitHub Pages

Automatic: `.github/workflows/firmware.yml` runs on every `firmware-v*` tag. It builds the release, attaches the images to the GitHub release, and deploys this folder to Pages. Set **Settings → Pages → Source** to **GitHub Actions** once.

By hand:
1. Run `ESPDeck Device/tools/release.sh X.Y.Z`.
2. Publish this folder, including `firmware/`, with Pages. Either commit it and choose **Deploy from a branch**, or upload it with the `actions/upload-pages-artifact` and `actions/deploy-pages` actions.

Pages serves over HTTPS, which Web Serial requires. To try the page locally, serve this folder from `localhost` (for example `python3 -m http.server` in `web/`); opening `index.html` as a file won't work.
