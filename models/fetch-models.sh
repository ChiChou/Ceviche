#!/bin/bash
# Produces the Core ML models in models/build. The app build (app/scripts/xcode-phase.sh) compiles them into
# models/build/compiled, which a debug build can see, and bundles the few in models.sh MODEL_BUNDLED; users download the
# rest in the app. Nothing here is committed. Modes:
#   fetch-models.sh            download the pinned sources, verify their SHA-256, convert every model locally and
#                              write the INT8 copies (models.sh MODEL_INT8) with quantize_int8.py
#   fetch-models.sh --sky      the same for the sky model only
#   fetch-models.sh --prebuilt [Name ...]
#                              download the converted models of the model set pinned in
#                              app/Sources/CevicheCore/Resources/ModelSet.json, verified against its checksums; only
#                              the named ones when names are given (the release build fetches MODEL_BUNDLED this way)
# Model sets are GitHub releases (models-v1, models-v2, ...) made by .github/workflows/models.yml from
# models/package-models.sh, versioned apart from the app; `make models-pin TAG=...` updates the pin.
set -euo pipefail
ML="$(cd "$(dirname "$0")" && pwd)"
CACHE="$ML/cache"; BUILD="$ML/build"
MANIFEST="$ML/../app/Sources/CevicheCore/Resources/ModelSet.json"
source "$ML/models.sh"
mkdir -p "$CACHE" "$BUILD"

verify() { # path sha256
    local actual; actual="$(shasum -a 256 "$1" | cut -d' ' -f1)"
    [[ "$actual" == "$2" ]] || { printf 'Checksum mismatch for %s\n  expected %s\n  actual   %s\n' "$1" "$2" "$actual" >&2; exit 1; }
}
download() { # url path sha256
    if [[ ! -f "$2" ]] || ! verify "$2" "$3" 2>/dev/null; then
        printf 'Downloading %s\n' "$(basename "$2")"
        mkdir -p "$(dirname "$2")"
        curl -fL --retry 3 -o "$2.partial" "$1"
        mv "$2.partial" "$2"
    fi
    verify "$2" "$3"
}

if [[ "${1:-}" == "--prebuilt" ]]; then
    shift; ONLY=" $* "
    # Tag, repository and checksums come from the manifest this build pins; the archives are kept in the cache and a
    # model is unpacked again only when its archive changed. The models are touched so the app build does not take the
    # checkout's newer convert scripts as a reason to reconvert them.
    manifest() { python3 -I -c 'import json, sys; m = json.load(open(sys.argv[1])); print(eval(sys.argv[2], {"m": m}) or "")' "$MANIFEST" "$1"; }
    TAG="$(manifest 'm.get("tag")')"; REPO="$(manifest 'm["repository"]')"
    [[ -n "$TAG" ]] || { printf '%s pins no model set yet. Publish one with the Models workflow and run make models-pin TAG=models-vN, or run %s without --prebuilt.\n' "$MANIFEST" "$0" >&2; exit 1; }
    DIST="$CACHE/prebuilt/$TAG"; mkdir -p "$DIST"
    base="https://github.com/$REPO/releases/download/$TAG"
    printf 'Prebuilt models of %s from %s\n' "$TAG" "$base"
    for name in "${MODEL_NAMES[@]}"; do
        key="${name%.*}"
        [[ "$ONLY" == "  " || "$ONLY" == *" $key "* ]] || continue
        file="$(manifest "m['models']['$key']['file']")"; sha="$(manifest "m['models']['$key']['sha256']")"
        [[ -n "$file" && -n "$sha" ]] || { printf '%s has no entry for %s.\n' "$MANIFEST" "$key" >&2; exit 1; }
        if [[ -e "$BUILD/$name" && -f "$DIST/$name.sha256" && "$(cat "$DIST/$name.sha256")" == "$sha" ]]; then continue; fi
        download "$base/$file" "$DIST/$file" "$sha"
        rm -rf "${BUILD:?}/${name:?}" "${DIST:?}/${key:?}"
        aa extract -i "$DIST/$file" -d "$DIST"
        [[ -e "$DIST/$key/$name" ]] || { printf '%s did not contain %s/%s.\n' "$file" "$key" "$name" >&2; exit 1; }
        mv "$DIST/$key/$name" "$BUILD/$name"; rm -rf "${DIST:?}/${key:?}"
        touch "$BUILD/$name"
        printf '%s' "$sha" > "$DIST/$name.sha256"
    done
    printf 'Models ready in %s\n' "$BUILD"
    exit 0
fi

# Conversions run in models/.venv unless ML_PYTHON names an interpreter with requirements.txt installed.
PYTHON="${ML_PYTHON:-}"
ensure_python() {
    [[ -n "$PYTHON" ]] && return
    [[ -x "$ML/.venv/bin/python" ]] || uv venv --python 3.12 "$ML/.venv"
    uv pip install -q --python "$ML/.venv/bin/python" -r "$ML/requirements.txt"
    PYTHON="$ML/.venv/bin/python"
}

# Apple Core ML conversions on Hugging Face (Apache-2.0), pinned to a revision.
apple_package() { # repo revision package manifest_sha model_sha weights_sha
    local base="https://huggingface.co/$1/resolve/$2/$3"
    download "$base/Manifest.json" "$CACHE/$3/Manifest.json" "$4"
    download "$base/Data/com.apple.CoreML/model.mlmodel" "$CACHE/$3/Data/com.apple.CoreML/model.mlmodel" "$5"
    download "$base/Data/com.apple.CoreML/weights/weight.bin" "$CACHE/$3/Data/com.apple.CoreML/weights/weight.bin" "$6"
    rm -rf "$BUILD/$3"; cp -R "$CACHE/$3" "$BUILD/$3"
}
if [[ "${1:-}" != "--sky" ]]; then
apple_package apple/coreml-depth-anything-v2-small cfef6f6f2a70783dedc0bfae40cecbc2052285d3 DepthAnythingV2SmallF16.mlpackage \
    2883ae290c48fe916dc5ececac03a7d847fa277165a49ef5652fa1d2b9cb55f7 44ac97a3efcfd52113183fb2862ff59cd0368e9ec2e30a90a54980dd11407042 fa60d9b6a155734f59029ebb882fd54e549bfaee3539c1a9cbd2cbbab64a0fed
apple_package apple/coreml-detr-semantic-segmentation 7c771f8867a479d1441ac5fb0a8de31feea76bb6 DETRResnet50SemanticSegmentationF16.mlpackage \
    0749549c6b11139e11a40aaab82add4843a9977010337e596cce3dbb35c98512 61e05678150bcae26deac589b998dffe13c2977a9ba6f802938a9f3a60bfdcce 2f4de3dfed1aeced35ad7096d7c8721fcfb59571110a9e9138d73a7e56480408

# Official NAFNet-SIDD-width32 weights (megvii-research/NAFNet README, MIT), converted locally.
download "https://drive.usercontent.google.com/download?id=1lsByk21Xw-6aW7epCwOQxvm6HYCQZPHZ&export=download&confirm=t" \
    "$CACHE/NAFNet-SIDD-width32.pth" 89c70e808d1783b6c07911306e106aaf0d4f7f3da8c61078b99ff7f8929a26f4
if [[ ! -d "$BUILD/NAFNetSIDD32.mlpackage" || "$ML/convert_nafnet.py" -nt "$BUILD/NAFNetSIDD32.mlpackage" ]]; then
    ensure_python
    rm -rf "$BUILD/NAFNetSIDD32.mlpackage"
    (cd "$ML" && "$PYTHON" convert_nafnet.py "$CACHE/NAFNet-SIDD-width32.pth" "$BUILD/NAFNetSIDD32.mlpackage")
fi

# The Big-LaMa inpainting checkpoint (advimman/lama, Apache-2.0), converted locally by convert_lama.py.
download "https://huggingface.co/smartywu/big-lama/resolve/05cb2be7f8dbe6ca7c6e78f4fc827a4b2baaa4a9/big-lama.zip" \
    "$CACHE/big-lama.zip" f1b358ca24093b93a106183b98a3dea6e8ed09f3b43ea7251eb2c81e7b4575f6
if [[ ! -f "$CACHE/big-lama.ckpt" ]]; then
    unzip -p "$CACHE/big-lama.zip" big-lama/models/best.ckpt > "$CACHE/big-lama.ckpt.partial"
    mv "$CACHE/big-lama.ckpt.partial" "$CACHE/big-lama.ckpt"
fi
verify "$CACHE/big-lama.ckpt" fccb7adffd53ec0974ee5503c3731c2c2f1e7e07856fd9228cdcc0b46fd5d423
if [[ ! -d "$BUILD/BigLaMa.mlpackage" || "$ML/convert_lama.py" -nt "$BUILD/BigLaMa.mlpackage" || "$ML/lama_arch.py" -nt "$BUILD/BigLaMa.mlpackage" ]]; then
    ensure_python
    (cd "$ML" && "$PYTHON" convert_lama.py "$CACHE/big-lama.ckpt" "$BUILD/BigLaMa.mlpackage")
fi

# Alibaba's skin-retouching model (ModelScope iic/cv_unet_skin_retouching_torch, Apache-2.0): the blemish detector
# from its joint checkpoint and its even-tone network, converted locally by convert_blemish.py and convert_skin_tone.py.
SKIN="https://www.modelscope.cn/models/iic/cv_unet_skin_retouching_torch/resolve/30ddc0087d8dbfc4e7605dfd93f043c087858d0b"
download "$SKIN/joint_20210926.pth" "$CACHE/joint_20210926.pth" c9e1388b19d9334c90db08308c86de208f535920ee381ae8a9cb63484a78351a
if [[ ! -d "$BUILD/BlemishDetector.mlpackage" || "$ML/convert_blemish.py" -nt "$BUILD/BlemishDetector.mlpackage" ]]; then
    ensure_python
    rm -rf "$BUILD/BlemishDetector.mlpackage"
    (cd "$ML" && "$PYTHON" convert_blemish.py "$CACHE/joint_20210926.pth" "$BUILD/BlemishDetector.mlpackage")
fi
download "$SKIN/pytorch_model.pt" "$CACHE/skin_even_tone.pt" 760d0c0b95c4e0a692165677fe2b82dbdf8fbbd4a3780ca966599c627b082993
if [[ ! -d "$BUILD/SkinTone.mlpackage" || "$ML/convert_skin_tone.py" -nt "$BUILD/SkinTone.mlpackage" ]]; then
    ensure_python
    rm -rf "$BUILD/SkinTone.mlpackage"
    (cd "$ML" && "$PYTHON" convert_skin_tone.py "$CACHE/skin_even_tone.pt" "$BUILD/SkinTone.mlpackage")
fi

# MediaPipe's Selfie Multiclass segmentation (Google, Apache-2.0 per its model card), converted locally by
# convert_people_parts.py.
download "https://storage.googleapis.com/mediapipe-models/image_segmenter/selfie_multiclass_256x256/float32/1/selfie_multiclass_256x256.tflite" \
    "$CACHE/selfie_multiclass_256x256.tflite" c6748b1253a99067ef71f7e26ca71096cd449baefa8f101900ea23016507e0e0
if [[ ! -d "$BUILD/PeopleParts.mlpackage" || "$ML/convert_people_parts.py" -nt "$BUILD/PeopleParts.mlpackage" || "$ML/tflite_mil.py" -nt "$BUILD/PeopleParts.mlpackage" ]]; then
    ensure_python
    rm -rf "$BUILD/PeopleParts.mlpackage"
    (cd "$ML" && "$PYTHON" convert_people_parts.py "$CACHE/selfie_multiclass_256x256.tflite" "$BUILD/PeopleParts.mlpackage")
fi

# The face mesh in MediaPipe's Face Landmarker bundle (Google, Apache-2.0 per its model card), converted locally by
# convert_face_mesh.py; the bundle's face detector and blendshape model are not used.
download "https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/float16/1/face_landmarker.task" \
    "$CACHE/face_landmarker.task" 64184e229b263107bc2b804c6625db1341ff2bb731874b0bcc2fe6544e0bc9ff
if [[ ! -d "$BUILD/FaceMesh.mlpackage" || "$ML/convert_face_mesh.py" -nt "$BUILD/FaceMesh.mlpackage" || "$ML/tflite_mil.py" -nt "$BUILD/FaceMesh.mlpackage" ]]; then
    ensure_python
    rm -rf "$BUILD/FaceMesh.mlpackage"
    (cd "$ML" && "$PYTHON" convert_face_mesh.py "$CACHE/face_landmarker.task" "$BUILD/FaceMesh.mlpackage")
fi

# OpenCV Zoo's SFace face recognizer (Apache-2.0) as the ONNX file at a pinned revision, converted locally by
# convert_sface.py, for People on the Faces wall.
download "https://media.githubusercontent.com/media/opencv/opencv_zoo/ba91a3b91d00d76e86540d4013f944bd6b514e39/models/face_recognition_sface/face_recognition_sface_2021dec.onnx" \
    "$CACHE/face_recognition_sface_2021dec.onnx" 0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79
if [[ ! -d "$BUILD/SFace.mlpackage" || "$ML/convert_sface.py" -nt "$BUILD/SFace.mlpackage" ]]; then
    ensure_python
    rm -rf "$BUILD/SFace.mlpackage"
    (cd "$ML" && "$PYTHON" convert_sface.py "$CACHE/face_recognition_sface_2021dec.onnx" "$BUILD/SFace.mlpackage")
fi

fi

# The U²-Net sky segmentation model (xiongzhu666, MIT) as the author's ONNX file mirrored on Hugging Face, converted
# locally by convert_sky.py.
download "https://huggingface.co/JianyuanWang/skyseg/resolve/3ba8c6df1d9ba9ff26f637c7ba9568ac11a9aa7f/skyseg.onnx" "$CACHE/skyseg.onnx" \
    ab9c34c64c3d821220a2886a4a06da4642ffa14d5b30e8d5339056a089aa1d39
if [[ ! -f "$BUILD/SkySegmentation.mlmodel" || "$ML/convert_sky.py" -nt "$BUILD/SkySegmentation.mlmodel" ]]; then
    ensure_python
    (cd "$ML" && "$PYTHON" convert_sky.py "$CACHE/skyseg.onnx" "$BUILD/SkySegmentation.mlmodel")
fi

# The INT8 copies a release offers beside the FP16 models, redone when the model or quantize_int8.py is newer.
for name in "${MODEL_NAMES[@]}"; do
    key="${name%%.*}"; model="$BUILD/$name"; int8="$BUILD/$key-INT8.${name##*.}"
    [[ " ${MODEL_INT8[*]} " == *" $key "* && -e "$model" ]] || continue
    if [[ ! -e "$int8" || "$model" -nt "$int8" || "$ML/quantize_int8.py" -nt "$int8" ]]; then
        ensure_python
        (cd "$ML" && "$PYTHON" quantize_int8.py "$model" "$int8")
    fi
done
printf 'Models ready in %s\n' "$BUILD"
