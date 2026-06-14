FieldMapperApp-14-msti-rvt-composite.swift

Base file:
- FieldMapperApp-13(1).swift

Added:
- New RVT/VAT toolbox visualization: Multi-Scale Topographic Index.
- New composite visualization: MSTI × VAT Composite.
- MSTI max-scale slider.
- MSTI multiply-strength slider for MSTI × VAT.
- Live-adjust panel support for MSTI multiply strength.
- Grayscale terrain overlays are registered/drawn as multiply-style overlays so RVT/VAT/MSTI products can be placed over GeoPDFs, USGS topo, imagery, or other basemap PDFs with transparency.
- Warm archaeological color ramp is enabled for MSTI.

Notes:
- Use “Multi-Scale Topographic Index” for a standalone multi-scale relief product.
- Use “MSTI × VAT Composite” when you want MSTI multiplied into the VAT visualization in one rendered overlay.
- Use the existing terrain opacity pill / live controls / Map Layer Stack to adjust final overlay transparency over the basemap.
