package helpers

import "strings"

// Tenancy / ownership label prefixes propagated from parent objects (ManagedCluster,
// Placement, ManagedClusterAddOn, …) onto controller-created children so multi-tenant
// hubs can route writes with the same labels as the parent.
//
// Keys under these prefixes are copied; existing destination keys are never overwritten
// (controller-owned labels win).
var PropagatedLabelPrefixes = []string{
	"gmaas.io/",
	"rafay.io/",
	"tenancy.k8smgmt.io/",
}

// IsPropagatedLabel reports whether key is a tenancy/ownership label to copy.
func IsPropagatedLabel(key string) bool {
	for _, prefix := range PropagatedLabelPrefixes {
		if strings.HasPrefix(key, prefix) {
			return true
		}
	}
	return false
}

// ExtractPropagatedLabels returns the subset of labels that should be copied to children.
func ExtractPropagatedLabels(src map[string]string) map[string]string {
	if len(src) == 0 {
		return nil
	}
	out := map[string]string{}
	for k, v := range src {
		if IsPropagatedLabel(k) {
			out[k] = v
		}
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

// MergePropagatedLabels copies tenancy/ownership labels from src into dst.
// Existing keys in dst are kept. Returns the merged map (allocates if dst is nil).
func MergePropagatedLabels(dst, src map[string]string) map[string]string {
	prop := ExtractPropagatedLabels(src)
	if len(prop) == 0 {
		if dst == nil {
			return map[string]string{}
		}
		return dst
	}
	if dst == nil {
		dst = map[string]string{}
	}
	for k, v := range prop {
		if _, exists := dst[k]; !exists {
			dst[k] = v
		}
	}
	return dst
}

// PropagatedLabelsChanged reports whether the propagated subset differs between old and new.
func PropagatedLabelsChanged(oldLabels, newLabels map[string]string) bool {
	oldProp := ExtractPropagatedLabels(oldLabels)
	newProp := ExtractPropagatedLabels(newLabels)
	if len(oldProp) != len(newProp) {
		return true
	}
	for k, v := range oldProp {
		if newProp[k] != v {
			return true
		}
	}
	return false
}
