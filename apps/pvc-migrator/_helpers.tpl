{{- define "pvc-migrator.fullname" -}}
{{- printf "%s-to-%s" .Values.sourcePVC .Values.destinationPVC | trunc 63 | trimSuffix "-" -}}
{{- end -}}