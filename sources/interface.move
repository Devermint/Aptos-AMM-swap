// Copyright 2022 OmniBTC Authors. Licensed under Apache-2.0 License.
// Modifications copyright 2025 Devermint
module swap::interface {
    use std::signer;
    use std::vector;

    use aptos_framework::coin;
    use aptos_std::comparator::{Self, Result};
    use aptos_std::type_info;
    use aptos_framework::fungible_asset::Metadata;
    use aptos_framework::object::Object;

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

    // public entry fun register_pool<X, Y>(account: &signer) {
    //     assert!(!controller::is_emergency(), ERR_EMERGENCY);
    //     assert!(coin::is_coin_initialized<X>(), ERR_NOT_COIN);
    //     assert!(coin::is_coin_initialized<Y>(), ERR_NOT_COIN);
    //
    //     if (is_order<X, Y>()) {
    //         implements::register_pool<X, Y>(account);
    //     } else {
    //         implements::register_pool<Y, X>(account);
    //     }
    // }
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

        // Lazily create pool if missing.
        if (!implements::is_pool_exists(x_meta, y_meta)) {
            implements::register_pool(account, x_meta, y_meta);
        };

        let (optimal_x, optimal_y) =
            implements::calc_optimal_coin_values(x_meta, y_meta, x_val, y_val);
        assert!(optimal_x >= x_val_min, ERR_INSUFFICIENT_X_AMOUNT);
        assert!(optimal_y >= y_val_min, ERR_INSUFFICIENT_Y_AMOUNT);

        // Pull funds (FA) from user and mint LP directly to user.
        // (All FA transfers happen inside `implements::mint`.)
        let _lp_minted = implements::mint(account, x_meta, y_meta, optimal_x, optimal_y);
    }
    // public entry fun add_liquidity<X, Y>(
    //     account: &signer,
    //     coin_x_val: u64,
    //     coin_x_val_min: u64,
    //     coin_y_val: u64,
    //     coin_y_val_min: u64,
    // ) {
    //     assert!(!controller::is_emergency(), ERR_EMERGENCY);
    //     assert!(is_order<X, Y>(), ERR_MUST_BE_ORDER);
    //
    //     assert!(coin::is_coin_initialized<X>(), ERR_NOT_COIN);
    //     assert!(coin::is_coin_initialized<Y>(), ERR_NOT_COIN);
    //
    //     // if pool not exits
    //     if (!implements::is_pool_exists<X,Y>()) {
    //         implements::register_pool<X, Y>(account);
    //     };
    //
    //     let (optimal_x, optimal_y) = implements::calc_optimal_coin_values<X, Y>(
    //         coin_x_val,
    //         coin_y_val,
    //     );
    //
    //     assert!(optimal_x >= coin_x_val_min, ERR_INSUFFICIENT_X_AMOUNT);
    //     assert!(optimal_y >= coin_y_val_min, ERR_INSUFFICIENT_Y_AMOUNT);
    //
    //     let coin_x_opt = coin::withdraw<X>(account, optimal_x);
    //     let coin_y_opt = coin::withdraw<Y>(account, optimal_y);
    //
    //     let lp_coins = implements::mint<X, Y>(
    //         coin_x_opt,
    //         coin_y_opt,
    //     );
    //
    //     let account_addr = signer::address_of(account);
    //     if (!coin::is_account_registered<LP<X, Y>>(account_addr)) {
    //         coin::register<LP<X, Y>>(account);
    //     };
    //     coin::deposit(account_addr, lp_coins);
    // }
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

        let (x_out, y_out) = implements::burn(account, x_meta, y_meta, lp_val);

        // Min-out checks.
        assert!(x_out >= min_x_out_val, ERR_COIN_OUT_NUM_LESS_THAN_EXPECTED_MINIMUM);
        assert!(y_out >= min_y_out_val, ERR_COIN_OUT_NUM_LESS_THAN_EXPECTED_MINIMUM);
    }
    // public entry fun remove_liquidity<X, Y>(
    //     account: &signer,
    //     lp_val: u64,
    //     min_x_out_val: u64,
    //     min_y_out_val: u64,
    // ) {
    //     assert!(!controller::is_emergency(), ERR_EMERGENCY);
    //     assert!(is_order<X, Y>(), ERR_MUST_BE_ORDER);
    //     let lp_coins = coin::withdraw<LP<X, Y>>(account, lp_val);
    //     let (coin_x, coin_y) = implements::burn<X, Y>(lp_coins);
    //
    //     assert!(coin::value(&coin_x) >= min_x_out_val, ERR_COIN_OUT_NUM_LESS_THAN_EXPECTED_MINIMUM);
    //     assert!(coin::value(&coin_y) >= min_y_out_val, ERR_COIN_OUT_NUM_LESS_THAN_EXPECTED_MINIMUM);
    //
    //     let account_addr = signer::address_of(account);
    //     coin::deposit(account_addr, coin_x);
    //     coin::deposit(account_addr, coin_y);
    // }
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
