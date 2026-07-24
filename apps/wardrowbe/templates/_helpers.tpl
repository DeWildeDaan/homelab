# apps/wardrowbe/templates/_helpers.tpl

{{- define "wardrowbe.backend.labels" -}}
app.kubernetes.io/name: wardrowbe-backend
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: wardrowbe
{{- end -}}

{{- define "wardrowbe.backend.selectorLabels" -}}
app.kubernetes.io/name: wardrowbe-backend
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "wardrowbe.frontend.labels" -}}
app.kubernetes.io/name: wardrowbe-frontend
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: wardrowbe
{{- end -}}

{{- define "wardrowbe.frontend.selectorLabels" -}}
app.kubernetes.io/name: wardrowbe-frontend
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "wardrowbe.worker.labels" -}}
app.kubernetes.io/name: wardrowbe-worker
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: wardrowbe
{{- end -}}

{{- define "wardrowbe.worker.selectorLabels" -}}
app.kubernetes.io/name: wardrowbe-worker
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Shared env block for backend + worker: DB/Redis connection strings (built via
k8s $(VAR) interpolation from secret-backed vars) and the AI settings.
*/}}
{{- define "wardrowbe.dataEnv" -}}
- name: DB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ .Values.db.appSecret }}
      key: password
- name: DATABASE_URL
  value: "postgresql+asyncpg://{{ .Values.db.user }}:$(DB_PASSWORD)@{{ .Values.db.host }}:5432/{{ .Values.db.name }}"
# wardrowbe's Redis URL parser (app/workers/settings.py) splits on ":" and does
# NOT support auth in the URL — so Redis runs without a password (ClusterIP,
# in-namespace only) and we use a plain host:port/db URL.
- name: REDIS_URL
  value: "redis://{{ .Values.redis.host }}:6379/0"
{{- end -}}

{{- define "wardrowbe.aiEnv" -}}
- name: AI_INTERNAL_ENABLED
  value: "{{ .Values.ai.internalEnabled }}"
- name: AI_VISION_ENABLED
  value: "{{ .Values.ai.visionEnabled }}"
- name: AI_TEXT_ENABLED
  value: "{{ .Values.ai.textEnabled }}"
- name: AI_BASE_URL
  value: "{{ .Values.ai.baseUrl }}"
- name: AI_API_KEY
  value: "{{ .Values.ai.apiKey }}"
- name: AI_VISION_MODEL
  value: "{{ .Values.ai.visionModel }}"
- name: AI_TEXT_MODEL
  value: "{{ .Values.ai.textModel }}"
- name: AI_TIMEOUT
  value: "{{ .Values.ai.timeout }}"
- name: AI_MAX_RETRIES
  value: "{{ .Values.ai.maxRetries }}"
{{- end -}}

{{- define "wardrowbe.oidcEnv" -}}
- name: OIDC_ISSUER_URL
  value: "{{ .Values.oidc.issuerUrl }}"
- name: OIDC_CLIENT_ID
  value: "{{ .Values.oidc.clientId }}"
- name: OIDC_CLIENT_SECRET
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secrets.name }}
      key: OIDC_CLIENT_SECRET
{{- end -}}
