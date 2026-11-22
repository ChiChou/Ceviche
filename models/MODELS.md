# Bundled models

Ceviche's Core ML models are converted by `models/fetch-models.sh` from pinned sources (revision and SHA-256) and
published as a model-set release on GitHub (`models-v1`, `models-v2`, ...) by the Models workflow, which runs
`models/package-models.sh`. None are committed to Git. FaceMesh, PeopleParts and SFace are small enough to be built
into the app (`MODEL_BUNDLED` in `models/models.sh`); the app downloads the rest on demand in
**Ceviche › Settings… › Models** from the set pinned in `app/Sources/CevicheCore/Resources/ModelSet.json`, verifies each archive
against the SHA-256 recorded there and unpacks it into its own folder in
`~/Library/Application Support/Ceviche/Models` as the archive has it: `<Name>/LICENSE` beside the compiled `<Name>/<Name>.mlmodelc`. All
model licenses are also in **Help › Open Source Licenses…**. Each model is its own release file, `<Name>.aar`: an
uncompressed Apple Archive holding `<Name>/<Name>.mlpackage` (or `.mlmodel`) and `<Name>/LICENSE`, the file named in
the table below, as listed in `models/models.sh`. Every model is optional and a missing one disables only its feature.
A model set changes only when a model does, independently of app versions.

The packaging script also builds `<Name>-INT8.aar` for eligible models using the copy that `quantize_int8.py` writes
(`MODEL_INT8` in `models/models.sh`): weights quantized linearly to 8 bits with one scale per output channel,
activations FP16, about half the size and as fast on the Neural Engine. Settings › Models offers a choice when the pinned manifest lists both archives.
The current pin, `models-v1`, lists one archive per model. DETR has no INT8 copy (it
loses whole labels at INT8) and Big-LaMa stays as it is; SFace ships only as INT8 (see below). For development, `make models` converts
locally and `make models-prebuilt` downloads the pinned set into `models/build`.

| Model | Used for | Source | License | Size |
|---|---|---|---|---|
| DepthAnythingV2SmallF16 | Depth masks | [apple/coreml-depth-anything-v2-small](https://huggingface.co/apple/coreml-depth-anything-v2-small) @ `cfef6f6f`, Core ML conversion of [Depth Anything V2](https://github.com/DepthAnything/Depth-Anything-V2) **Small** | Apache-2.0 (`Depth-Anything-V2-LICENSE`) | 48 MB |
| DETRResnet50SemanticSegmentationF16 | Scene masks (vegetation, water, mountains, buildings, ground) | [apple/coreml-detr-semantic-segmentation](https://huggingface.co/apple/coreml-detr-semantic-segmentation) @ `7c771f88`, Core ML conversion of [facebook/detr-resnet-50-panoptic](https://huggingface.co/facebook/detr-resnet-50-panoptic) | Apache-2.0 (`DETR-LICENSE`) | 96 MB |
| NAFNetSIDD32 | AI denoise | Official NAFNet-SIDD-width32 checkpoint from [megvii-research/NAFNet](https://github.com/megvii-research/NAFNet) (SHA-256 `89c70e80…a26f4`), converted by `convert_nafnet.py` to FP16 512×512 tiles | MIT, with BasicSR Apache-2.0 notices (`NAFNet-LICENSE`) | 56 MB |
| BigLaMa | Remove brush, AI fill | Big-LaMa checkpoint from [advimman/lama](https://github.com/advimman/lama) as mirrored at [smartywu/big-lama](https://huggingface.co/smartywu/big-lama) @ `05cb2be7` (checkpoint SHA-256 `fccb7adf…5d423`), converted by `convert_lama.py` to FP16 with functions for 512×512 and 1024×1024 windows that share weights | Apache-2.0 (`LaMa-LICENSE`) | 100 MB |
| BlemishDetector | Portrait › Find blemishes | Detector of Alibaba's skin-retouching model, [iic/cv_unet_skin_retouching_torch](https://modelscope.cn/models/iic/cv_unet_skin_retouching_torch) @ `30ddc008` (`joint_20210926.pth`, SHA-256 `c9e1388b…8351a`), converted by `convert_blemish.py` | Apache-2.0 (`SkinRetouching-LICENSE`) | 34 MB |
| SkinTone | Portrait › Even tone | Even-tone network of the same model (`pytorch_model.pt`, SHA-256 `760d0c0b…82993`), converted by `convert_skin_tone.py` to FP16 512×512 | Apache-2.0 (`SkinRetouching-LICENSE`) | 26 MB |
| PeopleParts | People masks | MediaPipe [Selfie Multiclass](https://ai.google.dev/edge/mediapipe/solutions/vision/image_segmenter) 256×256 (`selfie_multiclass_256x256.tflite`, version 1, SHA-256 `c6748b12…07e0e0`), converted by `convert_people_parts.py` to FP16 | Apache-2.0 per its model card (`MediaPipe-LICENSE`) | 8 MB |
| FaceMesh | Eyebrows, eyes, lips and teeth in People masks | Face mesh of MediaPipe's [Face Landmarker](https://ai.google.dev/edge/mediapipe/solutions/vision/face_landmarker) (`face_landmarker.task` version 1, SHA-256 `64184e22…0bc9ff`; `face_landmarks_detector.tflite` inside), converted by `convert_face_mesh.py` to FP16 | Apache-2.0 per its model card (`MediaPipe-LICENSE`) | 3 MB |
| SFace | People on the Faces wall | [SFace](https://github.com/opencv/opencv_zoo/tree/main/models/face_recognition_sface) from OpenCV Zoo @ `ba91a3b9` (`face_recognition_sface_2021dec.onnx`, SHA-256 `0ba9fbfa…87c34e79`), converted by `convert_sface.py`, INT8 weights | Apache-2.0 (`SFace-LICENSE`) | 10 MB |
| SkySegmentation | Sky masks | U²-Net sky segmentation from [xiongzhu666/Sky-Segmentation-and-Post-processing](https://github.com/xiongzhu666/Sky-Segmentation-and-Post-processing), the author's ONNX file as mirrored at [JianyuanWang/skyseg](https://huggingface.co/JianyuanWang/skyseg) @ `3ba8c6df` (SHA-256 `ab9c34c6…aa1d39`), converted by `convert_sky.py` to FP16 | MIT (`SkySegmentation-LICENSE`) | 88 MB |

`convert_sky.py` folds the graph's shape arithmetic at the fixed 320 × 320 input, keeps only the fused output and what
it needs, and maps its 119 convolutions (dilated up to 8), 112 ReLUs, 33 ceil-mode max poolings, 38 half-pixel bilinear
upsamplings, 51 concatenations, 11 additions and the sigmoid to Core ML, rejecting unknown operators. The ImageNet
normalization the model was trained with is put in front, so input is float RGB NCHW `[1,3,320,320]` encoded sRGB in
`[0,1]`; output is `[1,1,320,320]` sky probability. Weights are FP16. On 28 photos (SkyFinder webcams and night skies)
the converted model and ONNX Runtime CPU agreed to a mean absolute error of 0.00004 on the CPU and 0.00023 with every
compute unit (max 0.073), 0.012 % of pixels crossing 0.5; it takes about 12 ms a frame on an M4.

On 430 daylight SkyFinder frames it scored IoU 0.933 (3.0 % of pixels wrong, 7 % of frames below IoU 0.8), against
0.885 (5.0 %, 16 %) for SkyRemoval, the AGPL model it replaced; SkyRemoval failed mostly on overcast skies, this model
mostly on floodlit blue-hour frames. The same author's 2 MB u2netp model misses whole clear skies and is not used.

`convert_lama.py` reads the checkpoint with an allow-list unpickler, so none of the training objects pickled with it
run, and builds the generator from `lama_arch.py`. Every batch norm is folded into the convolutions summed before it:
unfolded, sums inside the local branch reach about 1.1e5 before their batch norm, past FP16's 65504, and the fill has
blocks of Inf on smooth areas. Folded, the whole model runs on the Neural Engine (0.10 s for 512, 0.46 s for 1024 on
an M4); against PyTorch FP32 the mean hole error is 0.002–0.007 and the script fails above 0.01 or on any non-finite value.

`convert_blemish.py` keeps only the `detection_net` weights of the joint checkpoint (its inpainting network is not
used: Heal and AI fill do that job). The detector scores a 768 × 768 face crop with one sigmoid probability for every
kind of mark, and Ceviche turns compact regions into editable Heal strokes. `convert_skin_tone.py` builds ModelScope's
`unet_deploy.UNet` without its deep-supervision heads and checks the Core ML model against PyTorch (blend layer error
under 0.004). The network sees the face crop at 512 × 512 and predicts a blend layer that Ceviche applies as soft light
on the full-resolution photo, so it evens blotches and redness while pores and hair keep the photo's own detail; it
takes about 0.1 s a face on an M4. The package's skin segmentation model (a TensorFlow export that segments the whole
photo at 192 × 192) and its RetinaFace detector are not used.

`tflite_mil.py` maps a TFLite graph to Core ML operator by operator (convolutions, depthwise and transposed
convolutions, max pooling, padding, PReLU, sigmoid, add, multiply, reshape, transpose, softmax, sum, bilinear and
nearest resizes, and half-precision weights), refusing any other; tensors keep TFLite's channels-last layout and the
convolutions are wrapped in transposes the optimizer folds away. `convert_people_parts.py` uses it for the 175
operators of Selfie Multiclass. Input is RGB scaled to −1…1 at 256 × 256; output is six class probabilities (background, hair,
body skin, face skin, clothes, others). Against the TFLite runtime the class of every pixel matched and probabilities
differed by at most 0.017. The model card puts surveillance and identity recognition out of scope and reports lower
mask quality on the darkest skin tones (IoU 68 against about 77). A People mask runs it on a square crop around one
person Vision finds and cuts the result to that person's mask.

`convert_face_mesh.py` takes only the face mesh from the Face Landmarker bundle (Vision finds the faces). It sees the face
with a quarter of its size around it at 256 × 256, RGB scaled to 0…1, and gives 478 points in the crop's pixels and a
face score; against the TFLite runtime the points differ by at most 0.27 px. People masks trace the lips, eyes, irises
and brows from it; without it they fall back to Vision's 76 landmarks, whose mouth line drifts on a wide-open mouth.

`convert_sface.py` maps SFace's ONNX graph (convolutions, batch norms, PReLU, the final linear layer and its own input
scaling) to Core ML and checks it against ONNX Runtime on random crops (cosine 0.99999). It sees a face aligned by
five points (eye centres, nose tip, mouth corners) to OpenCV's 112 × 112 template, RGB in 0…255, and gives 128 values;
Ceviche normalizes them and groups faces whose cosine similarity is 0.5 or more. On the 3,060 faces of a real catalog the
Core ML model agreed with OpenCV's own runtime to a cosine of 0.99999 or better and took 2.5 ms a face on an M4; of 162
labelled same-person pairs 145 scored above 0.5, and none of 82 different-person pairs did. The model is saved with INT8
weights, one scale per block of 32, which halves it to 10 MB at the same speed (per-channel scales were slower);
on real faces the INT8 embeddings keep a cosine of 0.9998 or better to the FP16 ones and no pair changed sides of
the threshold.

Only Depth Anything V2 **Small** is Apache-2.0; its Base/Large/Giant weights are CC-BY-NC-4.0 and must not be
substituted. Apple's Depth Pro checkpoint is research-only and is not used.

Training data: the sky model's training set is not published; the skin-retouching models were trained on annotated
FFHQ and collected portraits with synthesized blemishes; NAFNet-SIDD was trained on the SIDD dataset; Big-LaMa on Places365-Challenge, whose images are
distributed for non-commercial research and education; Depth Anything V2 and DETR on their published datasets (see
the upstream model cards). Dataset terms do not change the model licenses above, but
redistributors should review them.
