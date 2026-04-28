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

{{/* Resolved Secret name — either user-supplied existingSecret or chart-created. */}}
{{- define "claude-cli.secretName" -}}
{{- if .Values.auth.existingSecret -}}
{{- .Values.auth.existingSecret -}}
{{- else -}}
{{- include "claude-cli.fullname" . -}}
{{- end -}}
{{- end -}}

{{/*
GPU resolver — mirrors resolve_gpu() from job-submitting utility.
Input: .Values.gpu = { type: <JobGPUType>, count: <int> }
Whole GPUs set nvidia.com/gpu + nodeSelector on nvidia.com/gpu.product.
MIG instances set nvidia.com/<mig_type> only (no nodeSelector).
*/}}
{{- define "claude-cli.gpu.limits" -}}
{{- $g := .Values.gpu | default dict -}}
{{- if and $g.type $g.count -}}
{{- $count := $g.count | int -}}
{{- if eq $g.type "A100"        }}nvidia.com/gpu: {{ $count }}
{{- else if eq $g.type "A40"         }}nvidia.com/gpu: {{ $count }}
{{- else if eq $g.type "H100"        }}nvidia.com/gpu: {{ $count }}
{{- else if eq $g.type "Tesla P100"  }}nvidia.com/gpu: {{ $count }}
{{- else if eq $g.type "mig-1g.10gb" }}nvidia.com/mig-1g.10gb: {{ $count }}
{{- else if eq $g.type "mig-2g.20gb" }}nvidia.com/mig-2g.20gb: {{ $count }}
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
