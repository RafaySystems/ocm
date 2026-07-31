package helpers

import (
	"reflect"
	"testing"
)

func TestMergePropagatedLabels(t *testing.T) {
	tests := []struct {
		name string
		dst  map[string]string
		src  map[string]string
		want map[string]string
	}{
		{
			name: "nil src",
			dst:  map[string]string{"a": "1"},
			src:  nil,
			want: map[string]string{"a": "1"},
		},
		{
			name: "copy ownership, keep controller keys",
			dst: map[string]string{
				"cluster.open-cluster-management.io/placement": "p1",
			},
			src: map[string]string{
				"gmaas.io/partner-id":      "partner-a",
				"gmaas.io/organization-id": "org-a",
				"rafay.io/partner-id":      "partner-a",
				"rafay.io/org-id":          "org-a",
				"tenancy.k8smgmt.io/tenant-id": "t1",
				"unrelated":                "x",
			},
			want: map[string]string{
				"cluster.open-cluster-management.io/placement": "p1",
				"gmaas.io/partner-id":                          "partner-a",
				"gmaas.io/organization-id":                     "org-a",
				"rafay.io/partner-id":                          "partner-a",
				"rafay.io/org-id":                              "org-a",
				"tenancy.k8smgmt.io/tenant-id":                 "t1",
			},
		},
		{
			name: "do not overwrite existing ownership",
			dst: map[string]string{
				"gmaas.io/partner-id": "keep",
			},
			src: map[string]string{
				"gmaas.io/partner-id": "replace",
			},
			want: map[string]string{
				"gmaas.io/partner-id": "keep",
			},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := MergePropagatedLabels(tt.dst, tt.src)
			if !reflect.DeepEqual(got, tt.want) {
				t.Fatalf("got %#v want %#v", got, tt.want)
			}
		})
	}
}

func TestPropagatedLabelsChanged(t *testing.T) {
	if !PropagatedLabelsChanged(nil, map[string]string{"gmaas.io/partner-id": "a"}) {
		t.Fatal("expected change when adding ownership")
	}
	if PropagatedLabelsChanged(
		map[string]string{"gmaas.io/partner-id": "a", "other": "1"},
		map[string]string{"gmaas.io/partner-id": "a", "other": "2"},
	) {
		t.Fatal("non-propagated label change should be ignored")
	}
}
