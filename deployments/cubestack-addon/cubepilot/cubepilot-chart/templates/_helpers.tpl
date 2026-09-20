{{/* Common labels for all resources. */}}
{{- define "cubepilot.labels" -}}
app.kubernetes.io/name: cubepilot
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/*
Shared agent-runtime env block. Both the operator and the api process consume
config.Load() (internal/config), so they receive the same environment.
*/}}
{{- define "cubepilot.agentEnv" -}}
- name: CUBEPILOT_NAMESPACE
  value: {{ .Release.Namespace | quote }}
- name: CUBEPILOT_AGENT_IMAGE
  value: {{ .Values.agents.image | quote }}
- name: CUBEPILOT_AGENT_IMAGE_PULL_POLICY
  value: {{ .Values.imagePullPolicy | quote }}
- name: CUBEPILOT_GC_WINDOW
  value: {{ .Values.agents.gcWindow | quote }}
- name: CUBEPILOT_GC_WATERMARK
  value: {{ .Values.agents.gcWatermark | quote }}
- name: CUBEPILOT_USERS
  value: {{ .Values.agents.users | quote }}
- name: CUBEPILOT_REPLICAS
  value: {{ .Values.operator.replicas | quote }}
{{- end -}}
