"""Convert the trained hey-neon ONNX model to TFLite.

train.py's built-in conversion fails with KeyError: 'onnx::Flatten_0'. PyTorch
names graph tensors like `onnx::Flatten_0`, and onnx_tf sanitizes `::` to `__`
when building the tf.function signature but then looks the tensor up under its
original name. Renaming the tensors before conversion sidesteps the mismatch.

Usage (inside the container):
    python /work/scripts/export_tflite.py
"""

import logging
import os
import tempfile

import onnx
import tensorflow as tf
from onnx_tf.backend import prepare

ONNX_PATH = "/work/output/hey_neon/hey_neon.onnx"
TFLITE_PATH = "/work/output/hey_neon/hey_neon.tflite"

logging.basicConfig(level=logging.INFO)


def sanitize_names(model: onnx.ModelProto) -> int:
    """Rewrite any tensor name containing '::' to use '__' instead."""
    renames = {}

    def fix(name: str) -> str:
        if "::" in name:
            renames.setdefault(name, name.replace("::", "__"))
            return renames[name]
        return name

    g = model.graph
    for collection in (g.input, g.output, g.value_info, g.initializer):
        for item in collection:
            item.name = fix(item.name)
    for node in g.node:
        node.input[:] = [fix(i) for i in node.input]
        node.output[:] = [fix(o) for o in node.output]

    return len(renames)


def main():
    model = onnx.load(ONNX_PATH)
    print(f"input tensors before: {[i.name for i in model.graph.input]}")
    n = sanitize_names(model)
    print(f"renamed {n} tensor name(s); inputs now: {[i.name for i in model.graph.input]}")
    onnx.checker.check_model(model)

    with tempfile.TemporaryDirectory() as tmp:
        fixed_onnx = os.path.join(tmp, "fixed.onnx")
        onnx.save(model, fixed_onnx)

        tf_rep = prepare(onnx.load(fixed_onnx), device="CPU")
        saved_model = os.path.join(tmp, "tf_model")
        tf_rep.export_graph(saved_model)

        converter = tf.lite.TFLiteConverter.from_saved_model(saved_model)
        tflite_model = converter.convert()

    with open(TFLITE_PATH, "wb") as f:
        f.write(tflite_model)
    print(f"wrote {TFLITE_PATH} ({len(tflite_model)} bytes)")


if __name__ == "__main__":
    main()
