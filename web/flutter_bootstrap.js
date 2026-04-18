{{flutter_js}}
{{flutter_build_config}}

const _builds =
    (_flutter && _flutter.buildConfig && _flutter.buildConfig.builds) || [];
const _hasHtmlRenderer = _builds.some((build) => build.renderer === "html");

_flutter.loader.load({
  config: _hasHtmlRenderer ? { renderer: "html" } : {},
});
