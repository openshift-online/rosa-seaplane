{{/*
Expand the name of the chart.
*/}}
{{- define "seaplane-thanos.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "seaplane-thanos.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "seaplane-thanos.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
app.kubernetes.io/name: {{ include "seaplane-thanos.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Namespace
*/}}
{{- define "seaplane-thanos.namespace" -}}
{{- default "thanos" .Values.namespace }}
{{- end }}

{{/*
Helm release annotations - required for Helm to recognize ownership
*/}}
{{- define "seaplane-thanos.annotations" -}}
meta.helm.sh/release-name: {{ .Release.Name }}
meta.helm.sh/release-namespace: {{ .Release.Namespace }}
argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
{{- end }}

{{/*
Red Hat Thanos operand (CMO ose-thanos-rhel9). Operator concatenates
baseImage:version (tag may include @sha256:…) and sets args (query, receive, …).
Private-registry credentials are configured on the operand CRs and copied
to generated Pod specs by the operator.

securityContext is required: the operator sets container runAsNonRoot: true
and does not set runAsUser. ose-thanos-rhel9 uses USER nobody (non-numeric),
so kubelet fails CreateContainerConfigError until a numeric UID is set.
65534 matches CMO's Thanos pod securityContext (nobody on RHEL).
*/}}
{{- define "thanos.operandImage" -}}
baseImage: {{ .Values.image.repository | quote }}
version: {{ .Values.image.tag | quote }}
{{- with .Values.securityContext }}
securityContext:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}
