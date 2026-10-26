{{/*
Every team, with defaults merged in: chart defaults, then the team's entry in
values.yaml, then its entry under `teams:` in the environment file — which,
being passed later with -f, is already merged into .Values.teams by Helm.

deepCopy for the same reason as the services chart: mergeOverwrite mutates its
first argument, and without the copy the first team would absorb its
overrides into the shared defaults.
*/}}
{{- define "teams.all" -}}
{{- $out := dict -}}
{{- range $name, $cfg := .Values.teams -}}
  {{- $merged := mergeOverwrite (deepCopy $.Values.defaults) (deepCopy ($cfg | default dict)) -}}
  {{- $_ := set $out $name $merged -}}
{{- end -}}
{{- $out | toYaml -}}
{{- end -}}

{{- define "teams.labels" -}}
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
app.kubernetes.io/part-of: teams
helm.sh/chart: {{ printf "%s-%s" .root.Chart.Name .root.Chart.Version }}
team: {{ .name }}
{{- end -}}
