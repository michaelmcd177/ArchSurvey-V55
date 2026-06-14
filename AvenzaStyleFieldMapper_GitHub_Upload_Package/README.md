# Avenza-Style Archaeology Field Mapper

This repository package contains the updated single-file Swift source for the iOS archaeology field mapping app.

## Current app source

Use this file in Xcode:

`Source/AvenzaStyleFieldMapperApp.swift`

It is a full replacement source file based on the most recent app file supplied before this package. It includes the RVT/VAT terrain toolbox updates.

## New terrain / RVT additions

This version adds:

- Multi-Scale Topographic Index (MSTI) as an RVT-style visualization option.
- MSTI × VAT Composite visualization.
- MSTI max-scale control.
- MSTI multiply-strength control for blending MSTI into VAT.
- Live-adjust support for MSTI multiply settings.
- Multiply-style overlay behavior for grayscale RVT/VAT/MSTI outputs.
- Transparency controls for terrain overlays so RVT/VAT/MSTI visualizations can be viewed over GeoPDF, USGS topo, imagery, or other basemaps.

## How to use in Xcode

1. Open your existing Xcode project.
2. Back up the current Swift file.
3. Replace the existing app Swift source with `Source/AvenzaStyleFieldMapperApp.swift`.
4. Clean the build folder in Xcode.
5. Build and run on the iPhone.

## GitHub upload options

### Option 1: Upload as source repository files

Create a new GitHub repository and upload:

- `README.md`
- `.gitignore`
- `Source/AvenzaStyleFieldMapperApp.swift`
- `CHANGELOG.md`
- `docs/FieldMapperApp-14-msti-rvt-composite-readme.txt`

### Option 2: Upload ZIP as a release asset

Create a GitHub release and attach `AvenzaStyleFieldMapper_GitHub_Upload_Package.zip` as the release download.

## Notes

This package is not a full generated Xcode project. It is a GitHub-ready source package containing the updated Swift app file and documentation. If your app is currently a single-file Xcode project, replace that file with the source file in this package.
