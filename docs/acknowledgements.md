# Acknowledgements

Ceviche stands on published research and on other people's open work. The papers and methods below are the ones its
code implements or follows. Code, data and models it ships are credited with their licences in
[CREDITS.md](../app/licenses/CREDITS.md).

## Panorama

- M. Brown and D. G. Lowe, "Automatic Panoramic Image Stitching using Invariant Features", IJCV 2007: rotation
  model, wave correction and two-band blending.
- D. G. Lowe, "Distinctive Image Features from Scale-Invariant Keypoints", IJCV 2004: the ratio test for matching.
- C. Harris and M. Stephens, "A Combined Corner and Edge Detector", 1988.
- M. A. Fischler and R. C. Bolles, "Random Sample Consensus", CACM 1981.
- B. K. P. Horn, "Closed-form solution of absolute orientation using unit quaternions", JOSA A 1987.
- [OpenPano](https://github.com/ppwwyyxx/OpenPano) by Yuxin Wu and the OpenCV stitching module, read as reference
  implementations.

## HDR, stacking and alignment

- S. Umeyama, "Least-squares estimation of transformation parameters between two point patterns", PAMI 1991.
- B. D. Lucas and T. Kanade, "An Iterative Image Registration Technique", 1981.
- H. S. Malvar, L. He and R. Cutler, "High-quality linear interpolation for demosaicing of Bayer-patterned color
  images", ICASSP 2004.
- P. J. Burt and E. H. Adelson, "The Laplacian Pyramid as a Compact Image Code", 1983: multiscale fusion in Focus
  Stack.

## Masks, upright and retouching

- K. He, J. Sun and X. Tang, "Guided Image Filtering", ECCV 2010 / PAMI 2013.
- K. He, J. Sun and X. Tang, "Single Image Haze Removal Using Dark Channel Prior", CVPR 2009: Dehaze.
- J. Kopf, M. F. Cohen, D. Lischinski and M. Uyttendaele, "Joint Bilateral Upsampling", SIGGRAPH 2007.
- R. Grompone von Gioi, J. Jakubowicz, J.-M. Morel and G. Randall, "LSD: a Line Segment Detector", IPOL 2012.
- P. Heckbert, "Fundamentals of Texture Mapping and Image Warping", 1989: square-to-quad projection.

## Colour

- C. S. McCamy, "Correlated color temperature as an explicit function of chromaticity coordinates", 1992.
- G. Sharma, W. Wu and E. N. Dalal, "The CIEDE2000 Color-Difference Formula", 2005.
- G. D. Finlayson, M. Mackiewicz and A. Hurlbert, "Color Correction Using Root-Polynomial Regression", IEEE TIP
  2015.
- B. Ottosson, "A perceptual color space for image processing" (Oklab), 2020.

## Film

- The film model's boolean grain, adjacency effects, halation and printing density follow the
  [Fotufilm engine](https://github.com/DhaliwalX/fotufilm-engine), with Hurter–Driffield characteristic curves,
  SMPTE RP 180 printing density and the makers' published data sheets.

## Models

- L. Chen, X. Chu, X. Zhang and J. Sun, "Simple Baselines for Image Restoration" (NAFNet), ECCV 2022.
- R. Suvorov et al., "Resolution-robust Large Mask Inpainting with Fourier Convolutions" (LaMa), WACV 2022.
- L. Yang et al., "Depth Anything V2", NeurIPS 2024.
- X. Qin et al., "U²-Net: Going Deeper with Nested U-Structure for Salient Object Detection", 2020.
- N. Carion et al., "End-to-End Object Detection with Transformers" (DETR), ECCV 2020.
