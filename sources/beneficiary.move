// Copyright 2022 OmniBTC Authors. Licensed under Apache-2.0 License.
// Modifications copyright 2025 Devermint
module swap::beneficiary {
    use std::signer;
    use swap::implements::{beneficiary, withdraw_fee};
    use swap::controller::is_emergency;
    use aptos_framework::fungible_asset::Metadata;
    use aptos_framework::object::Object;

    const ERR_NO_PERMISSIONS: u64 = 400;
    const ERR_EMERGENCY: u64 = 401;

    /// Transfers all accumulated fees of the specified asset to the beneficiary account.
    public entry fun withdraw(
        asset_meta: Object<Metadata>, account: &signer
    ) {
        // Check we are not in emergency mode
        assert!(!is_emergency(), ERR_EMERGENCY);

        // Ensure only the designated beneficiary can withdraw
        assert!(beneficiary() == signer::address_of(account), ERR_NO_PERMISSIONS);

        // Withdraw the fees (now FA-based)
        withdraw_fee(asset_meta, signer::address_of(account));
    }
}
