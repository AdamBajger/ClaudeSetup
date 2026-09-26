{{- define "claude-cli.fullname" -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "claude-cli.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "claude-cli.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/* auth.authorizedKeys: list or multi-line string → one key per line. */}}
{{- define "claude-cli.authorizedKeys" -}}
{{- $ak := .Values.auth.authorizedKeys -}}
{{- if kindIs "slice" $ak -}}
{{- range $ak }}
{{ . | trim }}
{{- end -}}
{{- else -}}
{{- $ak -}}
{{- end -}}
{{- end -}}

{{- define "claude-cli.secretName" -}}
{{- .Values.auth.existingSecret | default (include "claude-cli.fullname" .) -}}
{{- end -}}

{{/* GPU (mirrors resolve_gpu()): whole GPU → nvidia.com/gpu + product nodeSelector; MIG → nvidia.com/<mig> only. */}}
{{- define "claude-cli.gpu.limits" -}}
{{- $g := .Values.gpu | default dict -}}
{{- if and $g.type $g.count -}}
{{- $count := $g.count | int -}}
{{- if has $g.type (list "A100" "A40" "H100" "Tesla P100") }}nvidia.com/gpu: {{ $count }}
{{- else if has $g.type (list "mig-1g.10gb" "mig-2g.20gb") }}nvidia.com/{{ $g.type }}: {{ $count }}
{{- else }}{{ fail (printf "Invalid gpu.type: %s" $g.type) }}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "claude-cli.gpu.nodeSelector" -}}
{{- $g := .Values.gpu | default dict -}}
{{- if and $g.type $g.count -}}
{{- if eq $g.type "A100"       }}nvidia.com/gpu.product: NVIDIA-A100-80GB-PCIe
{{- else if eq $g.type "A40"        }}nvidia.com/gpu.product: NVIDIA-A40
{{- else if eq $g.type "H100"       }}nvidia.com/gpu.product: NVIDIA-H100-NVL
{{- else if eq $g.type "Tesla P100" }}nvidia.com/gpu.product: Tesla-P100-SXM2-16GB
{{- end -}}
{{- end -}}
{{- end -}}
