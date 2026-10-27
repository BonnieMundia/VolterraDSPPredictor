# VolterraDSPPredictor — Documentation and slides

By Boniface Mundia · October 2026

## Download

| File | What it is | Download |
|---|---|---|
| Technical documentation (PDF, 15 pages) | Purpose, research gap, models and implementation, setup guide, nine simulation scenarios, results, references | [Download](https://github.com/BonnieMundia/VolterraDSPPredictor/releases/download/docs-v1.0/VolterraDSPPredictor_Documentation.pdf) · [View in repo](VolterraDSPPredictor_Documentation.pdf) |
| Presentation (PowerPoint, 10 slides) | Plain-language overview with speaker notes; editable | [Download](https://github.com/BonnieMundia/VolterraDSPPredictor/releases/download/docs-v1.0/VolterraDSPPredictor_Slides.pptx) · [View in repo](VolterraDSPPredictor_Slides.pptx) |
| Presentation (PDF) | The same 10 slides as a PDF | [Download](https://github.com/BonnieMundia/VolterraDSPPredictor/releases/download/docs-v1.0/VolterraDSPPredictor_Slides.pdf) · [View in repo](VolterraDSPPredictor_Slides.pdf) |

All three files are also attached to the [docs-v1.0 release](https://github.com/BonnieMundia/VolterraDSPPredictor/releases/tag/docs-v1.0).

## Contents of this folder

- `VolterraDSPPredictor_Documentation.html`: source of the documentation PDF.
- `VolterraDSPPredictor_Slides.html` and `make_slides.py`: source of the slides. The script writes both the `.pptx` and the `.html` from one slide definition.
- `screenshots/`: renders of the app's own views, made with real engine output.
- `slides_assets/`: chart panels cropped from the screenshots for the slides.

## Rebuilding

```sh
# Slides (.pptx + .html)
python3 -m venv /tmp/docvenv && /tmp/docvenv/bin/pip install python-pptx
/tmp/docvenv/bin/python docs/make_slides.py

# PDFs (headless Chrome)
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
"$CHROME" --headless=new --no-pdf-header-footer --print-to-pdf=docs/VolterraDSPPredictor_Documentation.pdf "file://$PWD/docs/VolterraDSPPredictor_Documentation.html"
"$CHROME" --headless=new --no-pdf-header-footer --print-to-pdf=docs/VolterraDSPPredictor_Slides.pdf "file://$PWD/docs/VolterraDSPPredictor_Slides.html"
```
