{{/*
Expand the name of the chart.
*/}}
{{- define "agentex.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "agentex.fullname" -}}
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
Create chart name and version as used by the chart label.
*/}}
{{- define "agentex.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "agentex.labels" -}}
helm.sh/chart: {{ include "agentex.chart" . }}
{{ include "agentex.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "agentex.selectorLabels" -}}
app.kubernetes.io/name: {{ include "agentex.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Validate required values
*/}}
{{- define "agentex.validateValues" -}}
{{- if not .Values.vision.githubRepo }}
  {{- fail "vision.githubRepo is required. Example: myorg/myrepo" }}
{{- end }}
{{- if not .Values.vision.awsRegion }}
  {{- fail "vision.awsRegion is required. Example: us-west-2" }}
{{- end }}
{{- if not .Values.vision.ecrRegistry }}
  {{- fail "vision.ecrRegistry is required. Example: 123456.dkr.ecr.us-west-2.amazonaws.com" }}
{{- end }}
{{- if not .Values.vision.s3Bucket }}
  {{- fail "vision.s3Bucket is required. Example: my-thoughts" }}
{{- end }}
{{- if not .Values.vision.clusterName }}
  {{- fail "vision.clusterName is required. Example: my-cluster" }}
{{- end }}
{{- end }}

{{/*
Validate on every render — called from NOTES.txt
*/}}
{{- define "agentex.notes" -}}
{{ include "agentex.validateValues" . }}
{{- end }}
