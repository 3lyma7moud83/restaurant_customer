{{flutter_js}}
{{flutter_build_config}}

const _builds =
    (_flutter && _flutter.buildConfig && _flutter.buildConfig.builds) || [];
const _availableRenderers = _builds
    .map((build) => build && build.renderer)
    .filter((renderer) => typeof renderer === "string");

let _preferredRenderer = null;
if (_availableRenderers.includes("canvaskit")) {
  _preferredRenderer = "canvaskit";
} else if (_availableRenderers.includes("skwasm")) {
  _preferredRenderer = "skwasm";
}

_flutter.loader.load({
  config: _preferredRenderer ? { renderer: _preferredRenderer } : {},
});
