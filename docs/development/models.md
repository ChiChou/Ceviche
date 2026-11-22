# Models

What the models Ceviche uses do and where they are used. Planned work is in `ROADMAP.md`.

## Models in the app

### Downloadable model set

All are optional (`BundledModel` in `CevicheCore/Analysis/BundledModels.swift`, pinned set `models-v1` in
`CevicheCore/Resources/ModelSet.json`, conversion in `models/`, described in `models/MODELS.md`). Loaded once per
process by `BundledModelCache`. PeopleParts, FaceMesh and SFace (INT8) are built into the app; the others are
downloaded. The pinned set provides one archive per model.

| Model | Output | Input, speed, size | Used in |
|---|---|---|---|
| **DepthAnythingV2SmallF16** | Relative inverse depth, normalized 1st–99th percentile | 518 × 392 (portraits turned to landscape and back); 48 MB. Edge error about 12.5 % of the depth span at 518; tiled 2× with a weighted median 9.7 %. | Depth masks (`RawRenderer+Selection.swift` `relativeDepth`); Focus Stack, where flat low-texture areas follow the frame chosen at the same depth (`FocusStacker+Sharpness.swift`); Eyedropper availability (`Eyedropper.swift`). |
| **DETRResnet50SemanticSegmentationF16** | Per-pixel COCO panoptic class ids (133 classes: 80 things incl. person, animals, vehicles, plus stuff such as sky, water, road) | 448 × 448; 96 MB | Scene masks (vegetation, water, mountains, buildings, ground, people, sky: `sceneMatte`); Distraction Removal's People row finds small and defocused people on tiles (`PeopleFinder.swift`, `RawRenderer.distractingPeople`, `RetouchPanel.swift`). |
| **NAFNetSIDD32** | Denoised sRGB; only the fine part of the change is kept | 512 tiles, 64 overlap, FP16; 56 MB; GPU copy beside the Neural Engine | AI Noise Reduction dialog (`DenoiseDialog.swift`, `PhotoDenoiser.swift`), Export at output size (`ExportOptions.swift`), Creative Filters' AI Noise Reduction (`FiltersModel.swift`). |
| **SkySegmentation** (U²-Net) | Sky probability | 320 × 320, about 12 ms on M4; 88 MB. Daylight IoU 0.933; weak on floodlit blue hour | Sky masks with guided refinement (`SkyMaskModel.swift`, `MaskRefinement.sky`); Night Sky analysis (`NightSkyAnalyzer+Sky.swift`); Timelapse Sky Noise Reduction (`TimelapseDenoiseGPU.swift`, `TimelapseModel.swift`); Stack's sky (`PhotoStacker.swift`); Creative Filters' Polarizer (`FilterRenderer.swift`). A RAW's embedded Apple sky matte wins when present. |
| **BigLaMa** | Inpainted RGB | Multifunction 512 (0.10 s) and 1024 (0.46 s) on M4, all on the Neural Engine; 100 MB | Remove brush AI fill (`Inpainting.swift`, `RetouchPanel.swift`); Distraction Removal strokes are generative when it is installed; Portrait's Face spots (`FacePanel.swift`); Panorama Fill Edges (`PanoramaBoundary.swift`, `PanoramaMergeView.swift`). |
| **BlemishDetector** | Per-pixel blemish probability | 768 × 768 face crop; 34 MB | Portrait › Find blemishes, turned into Heal strokes (`BlemishDetector.swift`). |
| **SkinTone** | Blend layer applied as soft light | 512 × 512 face crop, about 0.1 s a face; 26 MB | Portrait › Light › Even tone (`Adjustments/SkinTone.swift`, `FacePanel.swift`). |
| **PeopleParts** (Selfie Multiclass) | 6 classes: background, hair, body skin, face skin, clothes, other | 256 × 256 square crop around one Vision person; 8 MB | People masks (`RawRenderer+People.swift`, `PortraitMasks.swift`, `PeopleMaskChooser.swift`); Portrait Details. |
| **FaceMesh** | 478 face points and a face score | 256 × 256 face crop with a quarter margin; 3 MB; points within 0.27 px of TFLite | Eyes, irises, lips, teeth and brows in People masks; Touch Up (`RawRenderer+People.swift`, `PortraitToolbar.swift`). Falls back to Vision landmarks. |
| **SFace** | 128-value face embedding | 112 × 112 aligned face, INT8 weights | People groups faces by similarity between embeddings (`PeopleIndex.swift`). |

### Apple frameworks

| Request | Used in |
|---|---|
| `VNDetectFaceRectanglesRequest`, `VNDetectFaceLandmarksRequest`, `VNDetectFaceCaptureQualityRequest` | Import tagging and the Faces wall (`CatalogImporter.classifyLabels`, 1600 px decode); culling reports (`PhotoQuality.swift`, eye openness from the landmark outline); Check Faces; Straighten › Eyes (`StraightenEstimator.swift`); Facial Features (`FaceLiquify.swift`); Reframe (`PortraitFraming.swift`); blemish crops; ID Photo; Match Series (`SeriesMatcher.swift`). |
| `VNClassifyImageRequest` | Tags at import (up to 12 labels at confidence ≥ 0.2), feeding search and Album name suggestions; ID Photo. |
| `VNCalculateImageAestheticsScoresRequest`, `VNGenerateAttentionBasedSaliencyImageRequest`, `VNGenerateImageFeaturePrintRequest` | Culling measures aesthetics, utility and saliency and compares feature prints within bursts. Background indexing also generates feature prints for Show Similar Photos and Duplicates. |
| `VNGenerateForegroundInstanceMaskRequest` | Subject and Background masks; ID Photo background. |
| `VNGeneratePersonInstanceMaskRequest`, `VNDetectHumanRectanglesRequest` | People masks; Distraction Removal's person finding. |
| `VNGeneratePersonSegmentationRequest` | ID Photo. |
| Object selection (macOS 27 Vision) | Object masks (click inside the object). |
| `VNDetectRectanglesRequest`, `VNDetectDocumentSegmentationRequest` | Perspective crop. |
| `VNTranslationalImageRegistrationRequest` | Timelapse alignment. |
| Foundation Models (`LanguageModelSession`) | Album name suggestions from tags (`AlbumNamer.swift`); ID Photo review (`IDPhotoReview.swift`). Prompts are tuned with `/usr/bin/fm` first. |

Not used yet: text recognition, horizon detection, human and animal body pose, animal recognition, optical flow,
homographic registration, objectness saliency.
