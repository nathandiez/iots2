{{- define "iot-system.name" -}}
iot-system
{{- end }}

{{- define "iot-system.chart" -}}
{{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}