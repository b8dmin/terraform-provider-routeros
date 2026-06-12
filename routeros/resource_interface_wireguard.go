package routeros

import (
	"context"

	"github.com/hashicorp/terraform-plugin-sdk/v2/diag"
	"github.com/hashicorp/terraform-plugin-sdk/v2/helper/schema"
	"github.com/hashicorp/terraform-plugin-sdk/v2/helper/validation"
)

/*
  {
    ".id": "*55",
    "disabled": "false",
    "listen-port": "13231",
    "mtu": "1420",
    "name": "wireguard1",
    "private-key": "gLP306E2BCZBeyZ0ILrS5Ubdg4VjkFYiWkg7HpKYM10=",
    "public-key": "HhbyDzG6loyFAsB040GvnOcRH1Ks+M44utp6REaWPxo=",
    "running": "true"
  }
*/

// wireguardWoPairs lists (regular, write-only) field name pairs.
// The _wo variants accept ephemeral values (Terraform ≥ 1.10) and are never
// stored in state. When a _wo field is set it takes precedence and its value
// is forwarded to RouterOS under the same API key as the regular field.
var wireguardWoPairs = []struct{ regular, wo string }{
	{"private_key", "private_key_wo"},
}

// wireguardMergeWo copies every set _wo value into its corresponding regular
// field so that TerraformResourceDataToMikrotik picks it up under the correct
// RouterOS API key name.
func wireguardMergeWo(d *schema.ResourceData) {
	// Read _wo values from rawConfig rather than d.GetOk: during Update the SDK
	// does not surface WriteOnly attribute config values through GetOk (planned
	// state for WriteOnly is always null), so rawConfig is the reliable source.
	rawConfig := d.GetRawConfig()
	if !rawConfig.IsKnown() || rawConfig.IsNull() || !rawConfig.Type().IsObjectType() {
		return
	}
	attrTypes := rawConfig.Type().AttributeTypes()
	for _, p := range wireguardWoPairs {
		if _, exists := attrTypes[p.wo]; !exists {
			continue
		}
		woVal := rawConfig.GetAttr(p.wo)
		if woVal.IsNull() || !woVal.IsKnown() {
			continue
		}
		d.Set(p.regular, woVal.AsString())
	}
}

// wireguardClearWoFromState removes the regular sensitive field from state when
// the practitioner is managing it through the _wo variant. This prevents the
// RouterOS-returned value from leaking into state and causing a perpetual diff
// on the next plan.
//
// Unlike the wireless security profile, private_key is Computed: RouterOS
// auto-generates it when absent from the config. We therefore must NOT clear it
// merely because it is unset — that would wipe the auto-generated key from
// state for practitioners who use neither private_key nor private_key_wo. We
// only clear when the _wo variant is actually in use.
//
// The function is a no-op when rawConfig is unavailable (import, refresh
// without a plan) so that imported state is fully populated.
func wireguardClearWoFromState(d *schema.ResourceData) {
	rawConfig := d.GetRawConfig()
	if !rawConfig.IsKnown() || rawConfig.IsNull() || !rawConfig.Type().IsObjectType() {
		return
	}
	attrTypes := rawConfig.Type().AttributeTypes()
	for _, p := range wireguardWoPairs {
		if _, exists := attrTypes[p.wo]; !exists {
			continue
		}
		woVal := rawConfig.GetAttr(p.wo)
		if !woVal.IsNull() && woVal.IsKnown() {
			d.Set(p.regular, nil)
		}
	}
}

// ResourceInterfaceWireguard https://help.mikrotik.com/docs/display/ROS/WireGuard
func ResourceInterfaceWireguard() *schema.Resource {
	resSchema := map[string]*schema.Schema{
		MetaResourcePath: PropResourcePath("/interface/wireguard"),
		MetaId:           PropId(Id),

		// _wo fields are skipped in both read (RouterOS never returns them) and
		// write (their value is forwarded via the regular field in the custom
		// Create/Update context).
		MetaSkipFields: PropSkipFields("private_key_wo"),

		KeyComment:  PropCommentRw,
		KeyDisabled: PropDisabledRw,
		"listen_port": {
			Type:         schema.TypeInt,
			Required:     true,
			Description:  "Port for WireGuard service to listen on for incoming sessions.",
			ValidateFunc: validation.IntBetween(1, 65535),
		},
		KeyMtu:  PropMtuRw(),
		KeyName: PropNameForceNewRw,
		"private_key": {
			Type:          schema.TypeString,
			Computed:      true,
			Optional:      true,
			Sensitive:     true,
			ConflictsWith: []string{"private_key_wo"},
			Description: "A base64 private key. If not specified, it will be automatically " +
				"generated upon interface creation.",
		},
		"private_key_wo": {
			Type:          schema.TypeString,
			Optional:      true,
			Sensitive:     true,
			WriteOnly:     true,
			ConflictsWith: []string{"private_key"},
			Description: "Write-only alternative to `private_key` for use with ephemeral values " +
				"(requires Terraform ≥ 1.10). The value is forwarded to RouterOS but never stored in state. " +
				"Cannot be used together with `private_key`.",
		},
		"public_key": {
			Type:        schema.TypeString,
			Computed:    true,
			Description: "A base64 public key is calculated from the private key.",
		},
		KeyRunning: PropRunningRo,
	}

	return &schema.Resource{
		CreateContext: func(ctx context.Context, d *schema.ResourceData, m interface{}) diag.Diagnostics {
			wireguardMergeWo(d)
			diags := ResourceCreate(ctx, resSchema, d, m)
			wireguardClearWoFromState(d)
			return diags
		},
		ReadContext: func(ctx context.Context, d *schema.ResourceData, m interface{}) diag.Diagnostics {
			// Snapshot which regular fields are empty in the prior state BEFORE
			// reading from RouterOS. An empty value means the resource is managed
			// via the _wo variant — we must restore the empty value afterwards so
			// the RouterOS-returned key does not leak into state and cause a
			// perpetual diff on the next plan.
			// (rawConfig is unavailable during the refresh phase of terraform
			// plan, so we rely on prior-state emptiness instead of rawConfig. The
			// auto-generate case keeps a non-empty value in state because
			// wireguardClearWoFromState only clears when _wo is in use.)
			emptyInPrior := make(map[string]bool, len(wireguardWoPairs))
			for _, p := range wireguardWoPairs {
				emptyInPrior[p.regular] = d.Get(p.regular).(string) == ""
			}

			diags := ResourceRead(ctx, resSchema, d, m)

			for _, p := range wireguardWoPairs {
				if emptyInPrior[p.regular] {
					d.Set(p.regular, nil)
				}
			}
			return diags
		},
		UpdateContext: func(ctx context.Context, d *schema.ResourceData, m interface{}) diag.Diagnostics {
			wireguardMergeWo(d)
			diags := ResourceUpdate(ctx, resSchema, d, m)
			wireguardClearWoFromState(d)
			return diags
		},
		DeleteContext: DefaultDelete(resSchema),
		Importer: &schema.ResourceImporter{
			StateContext: ImportStateCustomContext(resSchema),
		},

		SchemaVersion: 1,
		StateUpgraders: []schema.StateUpgrader{
			{
				Type:    ResourceInterfaceWireguardV0().CoreConfigSchema().ImpliedType(),
				Upgrade: stateMigrationNameToId(resSchema[MetaResourcePath].Default.(string)),
				Version: 0,
			},
		},

		Schema: resSchema,
	}
}
