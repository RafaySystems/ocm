package grpc

import (
	"fmt"
	"os"
	"strings"

	"github.com/spf13/pflag"
)

// envGRPCInsecureSkipTLSVerify controls skipping TLS verify for gRPC hub connections.
// Unset or unknown values default to true (dev/test). Set to false, 0, or no for production.
const envGRPCInsecureSkipTLSVerify = "GRPC_INSECURE_SKIP_TLS_VERIFY"

func insecureSkipTLSVerifyFromEnv() bool {
	v := strings.TrimSpace(strings.ToLower(os.Getenv(envGRPCInsecureSkipTLSVerify)))
	switch v {
	case "false", "0", "no":
		return false
	case "true", "1", "yes":
		return true
	default:
		// Unset: match prior fork default for local testing against self-signed hubs.
		return true
	}
}

type Option struct {
	BootstrapConfigFile string
	ConfigFile          string
	// InsecureSkipTLSVerify skips verification of the hub gRPC server certificate when using TLS (mTLS).
	// Set via --grpc-insecure-skip-tls-verify or GRPC_INSECURE_SKIP_TLS_VERIFY. Dev/test only.
	InsecureSkipTLSVerify bool
}

func NewOptions() *Option {
	return &Option{}
}

func (o *Option) AddFlags(fs *pflag.FlagSet) {
	fs.StringVar(&o.BootstrapConfigFile, "grpc-bootstrap-config", o.BootstrapConfigFile, "")
	fs.StringVar(&o.ConfigFile, "grpc-config", o.ConfigFile, "")
	def := insecureSkipTLSVerifyFromEnv()
	fs.BoolVar(&o.InsecureSkipTLSVerify, "grpc-insecure-skip-tls-verify", def,
		"Skip TLS certificate verification for the gRPC hub connection (dev/test only). "+
			"Env "+envGRPCInsecureSkipTLSVerify+": unset defaults to skip; set false for production.")
}

func (o *Option) Validate() error {
	if o.ConfigFile == "" && o.BootstrapConfigFile == "" {
		return fmt.Errorf("config file should be set")
	}

	return nil
}
