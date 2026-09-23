# apps/printstash/templates/_helpers.tpl
{{- define "printstash.fullname" -}}
{{ .Release.Name }}
{{- end -}}

{{- define "printstash.labels" -}}
app.kubernetes.io/name: {{ include "printstash.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
