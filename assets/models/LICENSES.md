# Bundled AI models

| File | Source | Licence |
| --- | --- | --- |
| `ultraface-rfb-320.onnx` | [Ultra-Light-Fast-Generic-Face-Detector-1MB](https://github.com/Linzaer/Ultra-Light-Fast-Generic-Face-Detector-1MB) `version-RFB-320.onnx`, initializers removed from graph inputs (weights unchanged) | MIT |
| `yolo-v9-t-384-license-plates-end2end.onnx` | [open-image-models](https://github.com/ankandrew/open-image-models) release `assets` | MIT |
| `cct_xs_v1_global.onnx` | [fast-plate-ocr](https://github.com/ankandrew/fast-plate-ocr) release `arg-plates` (config: 9 slots, alphabet `0-9A-Z_`, 64x128 RGB) | MIT |

All inference runs on the device with ONNX Runtime; no images leave the device.
