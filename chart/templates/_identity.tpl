{{/*
External hostname of one platform app, resolved like templates/ingress.yaml:
`ingress.hosts.<name>` wins, else `<sub>.<platform.baseDomain>` (or the base
domain itself when sub is empty), else "".
Usage: include "stardelt.appHost" (list $ "trino" "trino")
*/}}
{{- define "stardelt.appHost" -}}
{{- $root := index . 0 -}}
{{- $name := index . 1 -}}
{{- $sub := index . 2 -}}
{{- $base := $root.Values.platform.baseDomain | default "" -}}
{{- $override := index ($root.Values.ingress.hosts | default dict) $name | default "" -}}
{{- if $override -}}
{{- $override -}}
{{- else if and $base $sub -}}
{{- printf "%s.%s" $sub $base -}}
{{- else -}}
{{- $base -}}
{{- end -}}
{{- end -}}

{{/* Validated identity mode; fails the render on anything unknown. */}}
{{- define "stardelt.identityMode" -}}
{{- $mode := .Values.identity.mode | default "none" -}}
{{- if not (has $mode (list "none" "platform" "external")) -}}
{{- fail (printf "identity.mode must be one of none|platform|external, got %q" $mode) -}}
{{- end -}}
{{- $mode -}}
{{- end -}}

{{/* Issuer URL every component validates tokens against. */}}
{{- define "stardelt.issuerUrl" -}}
{{- $mode := include "stardelt.identityMode" . -}}
{{- if eq $mode "platform" -}}
{{- printf "https://%s/realms/stardelt" (include "stardelt.appHost" (list . "keycloak" "id")) -}}
{{- else -}}
{{- .Values.identity.issuerUrl | default "" -}}
{{- end -}}
{{- end -}}

{{/*
Value of an existing Secret key (kept across `helm upgrade`), else a fresh
random one. Usage: include "stardelt.secretValue" (list $ "secret-name" "key")
`helm template` has no cluster to look up, so it always shows fresh values.
*/}}
{{- define "stardelt.secretValue" -}}
{{- $root := index . 0 -}}
{{- $name := index . 1 -}}
{{- $key := index . 2 -}}
{{- $existing := lookup "v1" "Secret" $root.Release.Namespace $name -}}
{{- if and $existing $existing.data (hasKey $existing.data $key) -}}
{{- index $existing.data $key -}}
{{- else -}}
{{- randAlphaNum 48 | b64enc -}}
{{- end -}}
{{- end -}}
