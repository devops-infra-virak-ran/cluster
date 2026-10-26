{{/*
Helpers shared by every template.

Each one takes an explicit context dict rather than relying on the dot, because
they are called from inside a `range` where the dot is the loop variable, not
the root. The convention throughout is:

    (dict "root" $ "name" $name "svc" $svc)

`root` is the chart context ($), `name` the service key from values.yaml, and
`svc` that service's settings after defaults have been merged in.
*/}}

{{/* chart name and version, for the helm.sh/chart label */}}
{{- define "services.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
The name every object for a service gets: <release>-<service>.

Prefixed with the release so two releases of this chart can share a namespace
without colliding. Truncated to 63 characters, the limit for a label value —
a longer name is rejected by the API server at apply time.
*/}}
{{- define "services.name" -}}
{{- printf "%s-%s" .root.Release.Name .name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Selector labels. These go in Deployment.spec.selector, which is IMMUTABLE:
once created, changing it means deleting and recreating the Deployment. So it
holds only the two things that never change for a given service — never the
version, never the image tag.
*/}}
{{- define "services.selectorLabels" -}}
app.kubernetes.io/name: {{ .name }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
{{- end -}}

{{/*
The full label set for metadata. Safe to change at any time, so it carries the
version as well.
*/}}
{{- define "services.labels" -}}
helm.sh/chart: {{ include "services.chart" .root }}
{{ include "services.selectorLabels" . }}
app.kubernetes.io/version: {{ .svc.image.tag | default .root.Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
app.kubernetes.io/part-of: {{ .root.Chart.Name }}
app.kubernetes.io/component: {{ .svc.group }}
{{- end -}}

{{/*
Flatten every group into one map of service name -> fully merged settings.

This is the only place the three tiers are combined, so every template starts
the same way and none of them repeat the merge:

    {{- $all := include "services.all" $ | fromYaml }}
    {{- range $name, $svc := $all }}

Each service also gets a `group` key, which becomes its component label.

global.groups, when set, limits this to the named groups. A team's release
renders its own services only, even though the environment file it is given
names every team's tags.

deepCopy matters: sprig's mergeOverwrite mutates its first argument, so
without it the first service rendered would permanently absorb its own
overrides into the shared defaults and every later service would inherit
them. That bug is invisible with one service and appears with two.

mergeOverwrite, not merge: the more specific tier must win, and `merge`
resolves collisions the other way around.
*/}}
{{- define "services.all" -}}
{{- $root := . -}}
{{- $out := dict -}}
{{- $only := $root.Values.global.groups | default list -}}
{{- range $group, $g := $root.Values.groups -}}
  {{- if or (not $only) (has $group $only) -}}
  {{- range $name, $cfg := ($g.services | default dict) -}}
    {{- if hasKey $out $name -}}
      {{- fail (printf "service %q is defined in more than one group; names must be unique across groups" $name) -}}
    {{- end -}}
    {{- $merged := deepCopy ($root.Values.defaults | default dict) -}}
    {{- $merged = mergeOverwrite $merged (deepCopy ($g.defaults | default dict)) -}}
    {{- $merged = mergeOverwrite $merged (deepCopy $cfg) -}}
    {{- $_ := set $merged "group" $group -}}
    {{/*
      Two conventions, so a service that follows them needs no keys at all:

        image.repository  defaults to the service name, because the ECR
                          repository is named after the service
        route             defaults to <routePrefix>/<name> when the group sets
                          a routePrefix

      Both are only defaults. Naming either one explicitly overrides it, which
      is what a service pulling a public image or serving at / does.
    */}}
    {{- $image := $merged.image | default dict -}}
    {{- if not $image.repository -}}
      {{- $_ := set $image "repository" $name -}}
      {{- $_ := set $merged "image" $image -}}
    {{- end -}}
    {{- if and (not $merged.route) $merged.routePrefix -}}
      {{- $_ := set $merged "route" (printf "%s/%s" (trimSuffix "/" $merged.routePrefix) $name) -}}
    {{- end -}}
    {{- $_ := set $out $name $merged -}}
  {{- end -}}
  {{- end -}}
{{- end -}}
{{- $out | toYaml -}}
{{- end -}}

{{/*
Fully-qualified image reference.

global.imageRegistry is prefixed only when the repository is not already
qualified — a repository containing a "/" with a dot or colon before it is
taken to carry its own registry host. That lets one entry point at ECR while
another uses a public image, with no per-service registry setting.
*/}}
{{- define "services.image" -}}
{{- $repo := required (printf "services.%s.image.repository is required" .name) .svc.image.repository -}}
{{- $registry := .root.Values.global.imageRegistry | default "" -}}
{{- $tag := .svc.image.tag | default .root.Chart.AppVersion -}}
{{- if and $registry (not (regexMatch "^[^/]+[.:][^/]*/" $repo)) -}}
{{- printf "%s/%s:%s" (trimSuffix "/" $registry) $repo $tag -}}
{{- else -}}
{{- printf "%s:%s" $repo $tag -}}
{{- end -}}
{{- end -}}
