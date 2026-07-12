# apps/wealthfolio/templates/_helpers.tpl
{{- define "wealthfolio.fullname" -}}
{{ .Release.Name }}
{{- end -}}

{{- define "wealthfolio.labels" -}}
app.kubernetes.io/name: {{ include "wealthfolio.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}