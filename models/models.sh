# The model set, sourced by fetch-models.sh, package-models.sh, install-models.sh and app/scripts/snapshot.sh: each converted model in
# models/build and the file in models/licenses that is its license. A release packs every model with that file as
# <Name>/LICENSE in <Name>.aar, and the app keeps it there in its <Name> folder.
MODEL_LICENSES=(
    DepthAnythingV2SmallF16.mlpackage:Depth-Anything-V2-LICENSE
    DETRResnet50SemanticSegmentationF16.mlpackage:DETR-LICENSE
    NAFNetSIDD32.mlpackage:NAFNet-LICENSE
    BigLaMa.mlpackage:LaMa-LICENSE
    SkySegmentation.mlmodel:SkySegmentation-LICENSE
    BlemishDetector.mlpackage:SkinRetouching-LICENSE
    SkinTone.mlpackage:SkinRetouching-LICENSE
    PeopleParts.mlpackage:MediaPipe-LICENSE
    FaceMesh.mlpackage:MediaPipe-LICENSE
    SFace.mlpackage:SFace-LICENSE
)
MODEL_NAMES=("${MODEL_LICENSES[@]%%:*}")
# Models a release also carries with INT8 weights, as <Name>-INT8.aar beside <Name>.aar, so users can choose either in
# Settings › Models and tell us which works better. quantize_int8.py writes them as <Name>-INT8.mlpackage (or .mlmodel)
# in models/build. DETR is left out (at INT8 it loses whole labels), and Big-LaMa stays as it is. SFace has no FP16
# copy: it is INT8 already.
MODEL_INT8=(DepthAnythingV2SmallF16 NAFNetSIDD32 SkySegmentation BlemishDetector SkinTone PeopleParts FaceMesh)
# Models compiled into the app bundle by app/scripts/xcode-phase.sh, small enough to need no download.
MODEL_BUNDLED=(FaceMesh PeopleParts SFace)
# The license file of a model, by file name (NAFNetSIDD32.mlpackage) or by name (NAFNetSIDD32).
model_license() {
    local entry file
    for entry in "${MODEL_LICENSES[@]}"; do
        file="${entry%%:*}"
        [[ "$file" == "$1" || "${file%%.*}" == "$1" ]] && { printf '%s' "${entry##*:}"; return; }
    done
    return 1
}
