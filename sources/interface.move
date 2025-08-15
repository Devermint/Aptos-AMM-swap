// Copyright 2022 OmniBTC Authors. Licensed under Apache-2.0 License.
// Modifications copyright 2025 Devermint
module swap::interface {
    use aptos_framework::fungible_asset::Metadata;
    use aptos_framework::object::{Self, Object};
    use swap::controller;
    use swap::implements;

    const ERR_NOT_COIN: u64 = 100;
    const ERR_THE_SAME_COIN: u64 = 101;
    const ERR_EMERGENCY: u64 = 102;
    const ERR_INSUFFICIENT_X_AMOUNT: u64 = 103;
    const ERR_INSUFFICIENT_Y_AMOUNT: u64 = 104;
    const ERR_MUST_BE_ORDER: u64 = 105;
    const ERR_COIN_OUT_NUM_LESS_THAN_EXPECTED_MINIMUM: u64 = 106;

    /// Initialize swap
    public entry fun initialize_swap(
        swap_admin: &signer,
        controller: address,
        beneficiary: address
    ) {
        implements::initialize_swap(swap_admin, controller, beneficiary);
    }

    /// Register a new liquidity pool for 'X'/'Y' pair.
    public entry fun register_pool(
        account: &signer,
        x_meta: Object<Metadata>,
        y_meta: Object<Metadata>
    ) {
        assert!(!controller::is_emergency(), ERR_EMERGENCY);
        implements::register_pool(account, x_meta, y_meta);
    }

    /// Add liquidity by amounts you’re willing to supply. We compute optimal amounts
    /// against the current reserves to maintain the pool ratio.
    public entry fun add_liquidity(
        account: &signer,
        x_meta: Object<Metadata>,
        y_meta: Object<Metadata>,
        x_val: u64,
        x_val_min: u64,
        y_val: u64,
        y_val_min: u64
    ) {
        assert!(!controller::is_emergency(), ERR_EMERGENCY);
        let (asset_a, asset_b, _) = implements::order_and_make_seed(&x_meta, &y_meta);

        // Align amounts and min amounts with canonical order
        let (aligned_x_val, aligned_y_val, aligned_x_min, aligned_y_min) =
            if (object::object_address(&asset_a) == object::object_address(&x_meta)) {
                (x_val, y_val, x_val_min, y_val_min)
            } else {
                (y_val, x_val, y_val_min, x_val_min)
            };

        // Lazily create pool if missing
        if (!implements::is_pool_exists(asset_a, asset_b)) {
            implements::register_pool(account, asset_a, asset_b);
        };

        let (optimal_x, optimal_y) = implements::calc_optimal_coin_values(asset_a, asset_b, aligned_x_val, aligned_y_val);

         // Check minimum amounts
        assert!(optimal_x >= aligned_x_min, ERR_INSUFFICIENT_X_AMOUNT);
        assert!(optimal_y >= aligned_y_min, ERR_INSUFFICIENT_Y_AMOUNT);

        // Pull funds and mint LP directly to user
        let _lp_minted = implements::mint(account, asset_a, asset_b, optimal_x, optimal_y);
    }

    /// Remove liquidity by burning LP amount and receiving X/Y back.
    public entry fun remove_liquidity(
        account: &signer,
        x_meta: Object<Metadata>,
        y_meta: Object<Metadata>,
        lp_val: u64,
        min_x_out_val: u64,
        min_y_out_val: u64
    ) {
        assert!(!controller::is_emergency(), ERR_EMERGENCY);
        let (asset_a, asset_b, _) = implements::order_and_make_seed(&x_meta, &y_meta);

        // Align amounts and min amounts with canonical order
        let (aligned_x_out_val, aligned_y_out_val) =
            if (object::object_address(&asset_a) == object::object_address(&x_meta)) {
                (min_x_out_val, min_y_out_val)
            } else {
                (min_y_out_val, min_x_out_val)
            };

        let (x_out, y_out) = implements::burn(account, asset_a, asset_b, lp_val);

        // Min-out checks.
        assert!(x_out >= aligned_x_out_val, ERR_COIN_OUT_NUM_LESS_THAN_EXPECTED_MINIMUM);
        assert!(y_out >= aligned_y_out_val, ERR_COIN_OUT_NUM_LESS_THAN_EXPECTED_MINIMUM);
    }

    /// Swap exact-in with a min-out constraint. `in_meta` and `out_meta` can be in any order.
    public entry fun swap(
        account: &signer,
        in_meta: Object<Metadata>,
        out_meta: Object<Metadata>,
        coin_in_value: u64,
        coin_out_min_value: u64
    ) {
        assert!(!controller::is_emergency(), ERR_EMERGENCY);
        // All reserve reads, k-invariant checks, fees, and FA transfers are handled inside.
        implements::swap(
            account,
            in_meta,
            out_meta,
            coin_in_value,
            coin_out_min_value
        );
    }
}
