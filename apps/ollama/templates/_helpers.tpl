# apps/ollama/templates/_helpers.tpl

{{- define "ollama.labels" -}}
app.kubernetes.io/name: ollama
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: ollama
{{- end -}}

{{- define "ollama.selectorLabels" -}}
app.kubernetes.io/name: ollama
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "open-webui.labels" -}}
app.kubernetes.io/name: open-webui
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: ollama
{{- end -}}

{{- define "open-webui.selectorLabels" -}}
app.kubernetes.io/name: open-webui
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
