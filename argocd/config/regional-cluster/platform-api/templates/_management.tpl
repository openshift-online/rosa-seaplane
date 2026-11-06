{{- define "platform-api.managementConfig" -}}
{{- if hasKey .Values.platformApi.authz "managementConfig" -}}
  {{- $text := .Values.platformApi.authz.managementConfig -}}
  {{- if not (kindIs "string" $text) -}}
    {{- fail "platformApi.authz.managementConfig must be a serialized YAML string" -}}
  {{- end -}}
  {{- if $text -}}
    {{- $parsed := fromYaml $text -}}
    {{- /* fromYaml coerces null to {}; fromYamlArray distinguishes it from an object. */ -}}
    {{- if or (hasKey $parsed "Error") (and (empty $parsed) (empty (fromYamlArray $text))) -}}
      {{- fail "platformApi.authz.managementConfig must be a YAML object with valid syntax" -}}
    {{- end -}}
  {{- end -}}
  {{- $text -}}
{{- end -}}
{{- end -}}
