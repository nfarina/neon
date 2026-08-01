"""Minimal stub for tensorflow_addons (no aarch64 wheels; project is EOL).

onnx_tf imports it eagerly for a handful of exotic ops (e.g. Hardmax) that
openWakeWord's small DNN models never use. Any attribute chain resolves to a
callable that raises only if actually invoked.
"""


class _Stub:
    def __init__(self, path="tensorflow_addons"):
        self._path = path

    def __getattr__(self, name):
        return _Stub(f"{self._path}.{name}")

    def __call__(self, *args, **kwargs):
        raise NotImplementedError(
            f"{self._path} is a stub — tensorflow_addons op not available on aarch64"
        )


def __getattr__(name):
    return _Stub(f"tensorflow_addons.{name}")
