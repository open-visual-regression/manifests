{{- define "ovr.name" -}}
{{- .Chart.Name -}}
{{- end -}}

{{- define "ovr.fullname" -}}
{{- .Release.Name -}}
{{- end -}}

{{- define "ovr.labels" -}}
app.kubernetes.io/name: {{ include "ovr.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{- define "ovr.selectorLabels" -}}
app.kubernetes.io/name: {{ include "ovr.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{- define "ovr.secretName" -}}
{{- if .Values.existingSecret -}}
{{ .Values.existingSecret }}
{{- else -}}
{{ include "ovr.fullname" . }}-secret
{{- end -}}
{{- end -}}

{{/*
Builds an image reference for one component (web/worker). Each component has
its own digest/tag, since a single chart-wide value can't pin two different
images to the same digest. Falls back to the chart-wide image.tag/digest when
a component doesn't set its own - digest takes precedence over tag either way.
*/}}
{{- define "ovr.image" -}}
{{- $digest := .digest | default .Values.image.digest -}}
{{- $tag := .tag | default .Values.image.tag -}}
{{- if $digest -}}
{{ .Values.image.registry }}/{{ .name }}@{{ $digest }}
{{- else -}}
{{ .Values.image.registry }}/{{ .name }}:{{ $tag }}
{{- end -}}
{{- end -}}
