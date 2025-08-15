// Copyright 2022 OmniBTC Authors. Licensed under Apache-2.0 License.
// Modifications copyright 2025 Devermint
module swap::implements {
    use std::option;
    use std::signer;
    use std::string::{Self, String};
    use aptos_framework::object::{Self, Object};
    use aptos_framework::fungible_asset::{
        Self,
        Metadata,
        FungibleAsset,
        MintRef,
        BurnRef,
        TransferRef
    };
    use aptos_framework::primary_fungible_store;
    use aptos_framework::timestamp;

    use aptos_framework::account::{Self, SignerCapability};
    use std::vector;
    use std::bcs;
    use swap::event;
    use swap::math;

    friend swap::interface;
    friend swap::controller;
    friend swap::beneficiary;

    const ERR_POOL_EXISTS_FOR_PAIR: u64 = 300;
    const ERR_POOL_DOES_NOT_EXIST: u64 = 301;
    const ERR_POOL_IS_LOCKED: u64 = 302;
    const ERR_INCORRECT_BURN_VALUES: u64 = 303;
    const ERR_COIN_OUT_NUM_LESS_THAN_EXPECTED_MINIMUM: u64 = 304;
    const ERR_NOT_ENOUGH_PERMISSIONS_TO_INITIALIZE: u64 = 306;
    const ERR_LIQUID_NOT_ENOUGH: u64 = 307;
    const ERR_SWAP_NOT_INITIALIZE: u64 = 308;
    const ERR_U64_OVERFLOW: u64 = 309;
    const ERR_OVERLIMIT_X: u64 = 310;
    const ERR_WRONG_AMOUNT: u64 = 311;
    const ERR_WRONG_RESERVE: u64 = 312;
    const ERR_INCORRECT_SWAP: u64 = 313;
    const ERR_POOL_FULL: u64 = 314;
    const ERR_DEPRECATED_FUNCTION: u64 = 315;

    const SYMBOL_PREFIX_LENGTH: u64 = 4;
    const FEE_MULTIPLIER: u64 = 30;
    const FEE_SCALE: u64 = 10000;
    const U64_MAX: u64 = 18446744073709551615;
    /// The max value of coin_x or coin_y in a pool.
    /// U64 MAX / FEE_SCALE
    const MAX_POOL_VALUE: u64 = 18446744073709551615 / 10000;

    /// Minimal liquidity.
    const MINIMAL_LIQUIDITY: u64 = 1000;

    /// Generate LP coin name and symbol for pair `X`/`Y`.
    /// ```
    /// name = "LP-" + symbol<X>() + "-" + symbol<Y>();
    /// symbol = symbol<X>()[0:4] + "-" + symbol<Y>()[0:4];
    /// ```
    /// For example, for `LP<BTC, USDT>`,
    /// the result will be `(b"LP-BTC-USDT", b"BTC-USDT")`
    public fun generate_lp_name_and_symbol(
        x_meta: Object<Metadata>, y_meta: Object<Metadata>
    ): (String, String) {
        let sym_x = fungible_asset::symbol(x_meta);
        let sym_y = fungible_asset::symbol(y_meta);

        let lp_name = string::utf8(b"");
        lp_name.append_utf8(b"LP-");
        lp_name.append(sym_x);
        lp_name.append_utf8(b"-");
        lp_name.append(sym_y);

        let lp_symbol = string::utf8(b"");
        lp_symbol.append(coin_symbol_prefix(sym_x));
        lp_symbol.append_utf8(b"-");
        lp_symbol.append(coin_symbol_prefix(sym_y));

        (lp_name, lp_symbol)
    }

    fun coin_symbol_prefix(sym: String): String {
        let prefix_length =
            if (sym.length() < SYMBOL_PREFIX_LENGTH) {
                sym.length()
            } else {
                SYMBOL_PREFIX_LENGTH
            };
        sym.sub_string(0, prefix_length)
    }

    // public fun generate_lp_name_and_symbol<X, Y>(): (String, String) {
    //     let lp_name = string::utf8(b"");
    //     string::append_utf8(&mut lp_name, b"LP-");
    //     string::append(&mut lp_name, coin::symbol<X>());
    //     string::append_utf8(&mut lp_name, b"-");
    //     string::append(&mut lp_name, coin::symbol<Y>());
    //
    //     let lp_symbol = string::utf8(b"");
    //     string::append(&mut lp_symbol, coin_symbol_prefix<X>());
    //     string::append_utf8(&mut lp_symbol, b"-");
    //     string::append(&mut lp_symbol, coin_symbol_prefix<Y>());
    //
    //     (lp_name, lp_symbol)
    // }
    //
    // fun coin_symbol_prefix<CoinType>(): String {
    //     let symbol = coin::symbol<CoinType>();
    //     let prefix_length = SYMBOL_PREFIX_LENGTH;
    //     if (string::length(&symbol) < SYMBOL_PREFIX_LENGTH) {
    //         prefix_length = string::length(&symbol);
    //     };
    //     string::sub_string(&symbol, 0, prefix_length)
    // }
    public struct LpAuth has key {
        lp_meta: Object<Metadata>,
        mint_ref: MintRef,
        burn_ref: BurnRef,
        transfer_ref: TransferRef
    }

    /// Liquidity pool with reserves.
    public struct LiquidityPool has key {
        x_meta: Object<Metadata>,
        y_meta: Object<Metadata>,

        // LP is a separate FA
        lp_meta: Object<Metadata>,
        timestamp: u64,
        // last block timestamp.
        x_cumulative: u128,
        // last price x cumulative.
        y_cumulative: u128,
        // last price y cumulative.
        pair_cap: SignerCapability
    }

    public struct Config has key {
        pool_cap: SignerCapability,
        fee_cap: SignerCapability,
        controller: address,
        beneficiary: address
    }

    fun pool_account(): signer acquires Config {
        assert!(exists<Config>(@swap), ERR_SWAP_NOT_INITIALIZE);

        let config = borrow_global<Config>(@swap);
        account::create_signer_with_capability(&config.pool_cap)
    }

    fun pool_address(): address acquires Config {
        assert!(exists<Config>(@swap), ERR_SWAP_NOT_INITIALIZE);

        let config = borrow_global<Config>(@swap);
        account::get_signer_capability_address(&config.pool_cap)
    }

    fun fee_account(): signer acquires Config {
        assert!(exists<Config>(@swap), ERR_SWAP_NOT_INITIALIZE);

        let config = borrow_global<Config>(@swap);
        account::create_signer_with_capability(&config.fee_cap)
    }

    fun fee_address(): address acquires Config {
        assert!(exists<Config>(@swap), ERR_SWAP_NOT_INITIALIZE);

        let config = borrow_global<Config>(@swap);
        account::get_signer_capability_address(&config.fee_cap)
    }

    public fun is_pool_exists(
        x_meta: Object<Metadata>, y_meta: Object<Metadata>
    ): bool acquires Config {
        let pair_address = get_pair_address(x_meta, y_meta);
        exists<LiquidityPool>(pair_address)
    }

    // public fun is_pool_exists<X,Y>():bool acquires Config {
    //     let pool_account = pool_account();
    //     let pool_address = signer::address_of(&pool_account);
    //     if (!exists<LiquidityPool<X, Y>>(pool_address)) {
    //         return false
    //     } else {
    //         return true
    //     }
    // }

    public(friend) fun beneficiary(): address acquires Config {
        assert!(exists<Config>(@swap), ERR_SWAP_NOT_INITIALIZE);

        borrow_global<Config>(@swap).beneficiary
    }

    public(friend) fun controller(): address acquires Config {
        assert!(exists<Config>(@swap), ERR_SWAP_NOT_INITIALIZE);

        borrow_global<Config>(@swap).controller
    }

    public(friend) fun initialize_swap(
        swap_admin: &signer,
        controller: address,
        beneficiary: address
    ) {
        assert!(
            signer::address_of(swap_admin) == @swap,
            ERR_NOT_ENOUGH_PERMISSIONS_TO_INITIALIZE
        );

        // Create the protocol’s resource accounts directly
        let (pool_acc, pool_cap) =
            account::create_resource_account(swap_admin, b"swap_account_seed");
        let (_fee_acc, fee_cap) =
            account::create_resource_account(swap_admin, b"fee_account_seed");

        move_to(
            swap_admin,
            Config { pool_cap, fee_cap, controller, beneficiary }
        );

        // Global events live under the pool account.
        event::initialize(&pool_acc);
    }

    // public(friend) fun initialize_swap(
    //     swap_admin: &signer,
    //     controller: address,
    //     beneficiary: address,
    // ) {
    //     assert!(signer::address_of(swap_admin) == @swap, ERR_NOT_ENOUGH_PERMISSIONS_TO_INITIALIZE);
    //
    //     let pool_cap = init::retrieve_signer_cap(swap_admin);
    //     let pool_account = account::create_signer_with_capability(&pool_cap);
    //     let (_signer, fee_cap) = account::create_resource_account(
    //         swap_admin,
    //         b"fee_account_seed"
    //     );
    //
    //     move_to(swap_admin, Config { pool_cap, fee_cap, controller, beneficiary });
    //
    //     event::initialize(&pool_account);
    // }
    public(friend) fun register_pool(
        caller: &signer,
        x_meta: Object<Metadata>,
        y_meta: Object<Metadata>
    ) acquires Config {
        let pool_admin = pool_account();
        let fee_acc = fee_account();
        let fee_addr = signer::address_of(&fee_acc);

        // 0) Enforce ordering by metadata address so each pair only has one pool
        let (asset_a, asset_b, seed) = order_and_make_seed(&x_meta, &y_meta);

        let (pair_signer, pair_cap) = account::create_resource_account(
            &pool_admin, seed
        );
        let pair_addr = signer::address_of(&pair_signer);

        // Ensure the pool for this pair doesn't already exist
        assert!(!exists<LiquidityPool>(pair_addr), ERR_POOL_EXISTS_FOR_PAIR);

        // 2) Create LP metadata object and make it primary-store-enabled
        let constructor_ref = object::create_sticky_object(pair_addr);
        let (lp_name, lp_symbol) = generate_lp_name_and_symbol(asset_a, asset_b);

        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            &constructor_ref,
            option::none(), // no max supply
            lp_name, // name bytes
            lp_symbol, // symbol bytes
            9,
            string::utf8(b""), // icon URI
            string::utf8(b"https://dapp.aptoslayer.ai") // project URI
        );

        // 3) Generate LP refs (mint/burn/transfer) and persist them
        let mint_ref = fungible_asset::generate_mint_ref(&constructor_ref);
        let burn_ref = fungible_asset::generate_burn_ref(&constructor_ref);
        let transfer_ref = fungible_asset::generate_transfer_ref(&constructor_ref);
        let lp_meta_signer = object::generate_signer(&constructor_ref);
        let lp_meta =
            object::address_to_object<Metadata>(signer::address_of(&lp_meta_signer));
        move_to(
            &lp_meta_signer,
            LpAuth { lp_meta, mint_ref, burn_ref, transfer_ref }
        );

        // 3) Pre-create primary stores for pool account (not required, but explicit)
        //    This uses ensure_primary_store_exists; transfer/mint would also create on demand.
        let _ = primary_fungible_store::ensure_primary_store_exists(pair_addr, asset_a);
        let _ = primary_fungible_store::ensure_primary_store_exists(pair_addr, asset_b);
        let _ = primary_fungible_store::ensure_primary_store_exists(pair_addr, lp_meta);
        let _ = primary_fungible_store::ensure_primary_store_exists(fee_addr, asset_a);
        let _ = primary_fungible_store::ensure_primary_store_exists(fee_addr, asset_b);

        // 4) Write LiquidityPoolFA (reserves start at 0 in primary stores)
        move_to<LiquidityPool>(
            &pair_signer,
            LiquidityPool {
                x_meta: asset_a,
                y_meta: asset_b,
                lp_meta,
                timestamp: 0,
                x_cumulative: 0,
                y_cumulative: 0,
                pair_cap
            }
        );

        // 7) Emit event with metadata addresses
        event::created_event(
            pool_address(),
            signer::address_of(caller),
            asset_a,
            asset_b
        );
    }

    // 'X', 'Y' must ordered.
    // public(friend) fun register_pool<X, Y>(
    //     account: &signer
    // ) acquires Config {
    //     let pool_account = pool_account();
    //     let pool_address = signer::address_of(&pool_account);
    //     let fee_account = fee_account();
    //     let fee_address = signer::address_of(&fee_account);
    //
    //     assert!(!exists<LiquidityPool<X, Y>>(pool_address), ERR_POOL_EXISTS_FOR_PAIR);
    //
    //     let (lp_name, lp_symbol) = generate_lp_name_and_symbol<X, Y>();
    //
    //     let (lp_burn_cap, lp_freeze_cap, lp_mint_cap) =
    //         coin::initialize<LP<X, Y>>(&pool_account, lp_name, lp_symbol, 8, true);
    //     coin::destroy_freeze_cap(lp_freeze_cap);
    //
    //     if (!coin::is_account_registered<X>(fee_address)) {
    //         coin::register<X>(&fee_account)
    //     };
    //
    //     if (!coin::is_account_registered<Y>(fee_address)) {
    //         coin::register<Y>(&fee_account)
    //     };
    //
    //     let pool = LiquidityPool<X, Y> {
    //         coin_x: coin::zero<X>(),
    //         coin_y: coin::zero<Y>(),
    //         timestamp: 0,
    //         x_cumulative: 0,
    //         y_cumulative: 0,
    //         lp_mint_cap,
    //         lp_burn_cap,
    //     };
    //     move_to(&pool_account, pool);
    //
    //     event::created_event<X, Y>(pool_address, signer::address_of(account));
    // }
    public fun get_reserves_size(
        x_meta: Object<Metadata>, y_meta: Object<Metadata>
    ): (u64, u64) acquires LiquidityPool, Config {
        let pair_addr = get_pair_address(x_meta, y_meta);

        assert!(exists<LiquidityPool>(pair_addr), ERR_POOL_DOES_NOT_EXIST);
        let pool = borrow_global<LiquidityPool>(pair_addr);

        let x_reserve = primary_fungible_store::balance(pair_addr, pool.x_meta);
        let y_reserve = primary_fungible_store::balance(pair_addr, pool.y_meta);

        (x_reserve, y_reserve)
    }

    // public fun get_reserves_size<X, Y>(): (u64, u64) acquires LiquidityPool, Config {
    //     let pool_address = pool_address();
    //
    //     assert!(exists<LiquidityPool<X, Y>>(pool_address), ERR_POOL_DOES_NOT_EXIST);
    //
    //     let pool = borrow_global<LiquidityPool<X, Y>>(pool_address);
    //
    //     let x_reserve = coin::value(&pool.coin_x);
    //     let y_reserve = coin::value(&pool.coin_y);
    //
    //     (x_reserve, y_reserve)
    // }
    public(friend) fun mint(
        user: &signer,
        x_meta: Object<Metadata>,
        y_meta: Object<Metadata>,
        x_in: u64,
        y_in: u64
    ): u64 acquires LiquidityPool, LpAuth, Config {
        let pair_addr = get_pair_address(x_meta, y_meta);
        assert!(exists<LiquidityPool>(pair_addr), ERR_POOL_DOES_NOT_EXIST);

        let pool = borrow_global_mut<LiquidityPool>(pair_addr);
        let auth = borrow_global<LpAuth>(object::object_address(&pool.lp_meta));

        // 1) PRE-READ RESERVES
        let rx_before = primary_fungible_store::balance(pair_addr, pool.x_meta);
        let ry_before = primary_fungible_store::balance(pair_addr, pool.y_meta);

        // 2) MOVE USER FUNDS -> PAIR PRIMARY STORES
        primary_fungible_store::transfer(user, pool.x_meta, pair_addr, x_in);
        primary_fungible_store::transfer(user, pool.y_meta, pair_addr, y_in);

        // 3) LP AMOUNT TO MINT
        let lp_supply_opt = fungible_asset::supply(auth.lp_meta);
        let lp_total =
            if (lp_supply_opt.is_some()) {
                lp_supply_opt.extract()
            } else { 0u128 };
        let minted: u64;
        if (lp_total == 0) {
            let initial = math::sqrt(x_in) * math::sqrt(y_in);
            assert!(initial > MINIMAL_LIQUIDITY, ERR_LIQUID_NOT_ENOUGH);
            minted = initial - MINIMAL_LIQUIDITY;
        } else {
            let xl = (lp_total) * (x_in as u128) / (rx_before as u128);
            let yl = (lp_total) * (y_in as u128) / (ry_before as u128);
            let liq_u128 = if (xl < yl) { xl }
            else { yl };
            assert!(liq_u128 < (U64_MAX as u128), ERR_U64_OVERFLOW);
            minted = (liq_u128 as u64);
        };

        // 4) MINT LP -> USER
        let user_addr = signer::address_of(user);
        let _ =
            primary_fungible_store::ensure_primary_store_exists(user_addr, auth.lp_meta);
        let lp_fa = fungible_asset::mint(&auth.mint_ref, minted);
        let user_lp_store = primary_fungible_store::primary_store(
            user_addr, auth.lp_meta
        );
        fungible_asset::deposit_with_ref(&auth.transfer_ref, user_lp_store, lp_fa);

        // 5) POST-STATE CHECKS & ORACLE
        let new_x = primary_fungible_store::balance(pair_addr, pool.x_meta);
        let new_y = primary_fungible_store::balance(pair_addr, pool.y_meta);
        assert!(new_x < MAX_POOL_VALUE, ERR_POOL_FULL);
        assert!(new_y < MAX_POOL_VALUE, ERR_POOL_FULL);

        event::added_event(
            pool_address(),
            pool.x_meta,
            pool.y_meta,
            x_in,
            y_in,
            minted
        );
        update_oracle(pair_addr, pool);
        minted
    }

    // public(friend) fun mint<X, Y>(
    //     coin_x: Coin<X>,
    //     coin_y: Coin<Y>,
    // ): Coin<LP<X, Y>>  acquires LiquidityPool, Config {
    //     let pool_address = pool_address();
    //     assert!(exists<LiquidityPool<X, Y>>(pool_address), ERR_POOL_DOES_NOT_EXIST);
    //
    //     let x_provided_val = coin::value<X>(&coin_x);
    //     let y_provided_val = coin::value<Y>(&coin_y);
    //
    //     let lp_coins_total = option::extract(&mut coin::supply<LP<X, Y>>());
    //     let provided_liq = if (0 == lp_coins_total) {
    //         let initial_liq = math::sqrt(x_provided_val) * math::sqrt(y_provided_val);
    //         assert!(initial_liq > MINIMAL_LIQUIDITY, ERR_LIQUID_NOT_ENOUGH);
    //         initial_liq - MINIMAL_LIQUIDITY
    //     } else {
    //         let (reserve_x, reserve_y) = get_reserves_size<X, Y>();
    //         let x_liq = (lp_coins_total as u128) * (x_provided_val as u128) / (reserve_x as u128);
    //         let y_liq = (lp_coins_total as u128) * (y_provided_val as u128) / (reserve_y as u128);
    //         if (x_liq < y_liq) {
    //             assert!(x_liq < (U64_MAX as u128), ERR_U64_OVERFLOW);
    //             (x_liq as u64)
    //         } else {
    //             assert!(y_liq < (U64_MAX as u128), ERR_U64_OVERFLOW);
    //             (y_liq as u64)
    //         }
    //     };
    //
    //     let pool = borrow_global_mut<LiquidityPool<X, Y>>(pool_address);
    //     coin::merge(&mut pool.coin_x, coin_x);
    //     coin::merge(&mut pool.coin_y, coin_y);
    //
    //     assert!(coin::value(&pool.coin_x) < MAX_POOL_VALUE, ERR_POOL_FULL);
    //     assert!(coin::value(&pool.coin_y) < MAX_POOL_VALUE, ERR_POOL_FULL);
    //
    //     event::added_event<X, Y>(pool_address, x_provided_val, y_provided_val, provided_liq);
    //     update_oracle<X, Y>(pool_address, pool);
    //
    //     let lp_coins = coin::mint<LP<X, Y>>(provided_liq, &pool.lp_mint_cap);
    //
    //     lp_coins
    // }
    public(friend) fun burn(
        user: &signer,
        x_meta: Object<Metadata>,
        y_meta: Object<Metadata>,
        lp_amount: u64
    ): (u64, u64) acquires LiquidityPool, LpAuth, Config {
        let pair_addr = get_pair_address(x_meta, y_meta);
        assert!(exists<LiquidityPool>(pair_addr), ERR_POOL_DOES_NOT_EXIST);

        let pool = borrow_global_mut<LiquidityPool>(pair_addr);
        let auth = borrow_global<LpAuth>(object::object_address(&pool.lp_meta));

        let rx = primary_fungible_store::balance(pair_addr, pool.x_meta);
        let ry = primary_fungible_store::balance(pair_addr, pool.y_meta);
        let lp_supply_opt = fungible_asset::supply(auth.lp_meta);
        let lp_total =
            if (lp_supply_opt.is_some()) {
                lp_supply_opt.extract()
            } else { 0u128 };

        let x_out = math::mul_div_u128(rx as u128, lp_amount as u128, lp_total) as u64;
        let y_out = math::mul_div_u128(ry as u128, lp_amount as u128, lp_total) as u64;
        assert!(x_out > 0 && y_out > 0, ERR_INCORRECT_BURN_VALUES);

        // Burn user's LP
        let user_addr = signer::address_of(user);
        let user_lp_store = primary_fungible_store::primary_store(
            user_addr, auth.lp_meta
        );
        fungible_asset::burn_from(&auth.burn_ref, user_lp_store, lp_amount);

        // Pay out X/Y from pair stores -> user using pair signer
        let pair_signer = account::create_signer_with_capability(&pool.pair_cap);
        primary_fungible_store::transfer(&pair_signer, pool.x_meta, user_addr, x_out);
        primary_fungible_store::transfer(&pair_signer, pool.y_meta, user_addr, y_out);

        event::removed_event(
            pool_address(),
            pool.x_meta,
            pool.y_meta,
            x_out,
            y_out,
            lp_amount
        );
        update_oracle(pair_addr, pool);
        (x_out, y_out)
    }

    // public(friend) fun burn<X, Y>(
    //     lp_coins: Coin<LP<X, Y>>,
    // ): (Coin<X>, Coin<Y>) acquires LiquidityPool, Config {
    //     let pool_address = pool_address();
    //     assert!(exists<LiquidityPool<X, Y>>(pool_address), ERR_POOL_DOES_NOT_EXIST);
    //
    //     let pool = borrow_global_mut<LiquidityPool<X, Y>>(pool_address);
    //
    //     let burned_lp_coins_val = coin::value(&lp_coins);
    //     let x_reserve_val = coin::value(&pool.coin_x);
    //     let y_reserve_val = coin::value(&pool.coin_y);
    //
    //     let lp_coins_total = option::extract(&mut coin::supply<LP<X, Y>>());
    //     let x_to_return_val = math::mul_div_u128(
    //         (x_reserve_val as u128),
    //         (burned_lp_coins_val as u128),
    //         lp_coins_total
    //     );
    //     let y_to_return_val = math::mul_div_u128(
    //         (y_reserve_val as u128),
    //         (burned_lp_coins_val as u128),
    //         lp_coins_total
    //     );
    //
    //     assert!(x_to_return_val > 0 && y_to_return_val > 0, ERR_INCORRECT_BURN_VALUES);
    //
    //     let x_coin_to_return = coin::extract(&mut pool.coin_x, x_to_return_val);
    //     let y_coin_to_return = coin::extract(&mut pool.coin_y, y_to_return_val);
    //
    //     event::removed_event<X, Y>(pool_address, x_to_return_val, y_to_return_val, burned_lp_coins_val);
    //     update_oracle<X, Y>(pool_address, pool);
    //
    //     coin::burn(lp_coins, &pool.lp_burn_cap);
    //
    //     (x_coin_to_return, y_coin_to_return)
    // }

    /// Calculate the output amount minus the fee - 0.3%
    public fun get_amount_out(
        coin_in: u64,
        reserve_in: u64,
        reserve_out: u64
    ): u64 {
        let fee_multiplier = FEE_SCALE - FEE_MULTIPLIER;

        let coin_in_val_after_fees = (coin_in as u128) * (fee_multiplier as u128);

        // reserve_in size after adding coin_in (scaled to 1000)
        let new_reserve_in =
            ((reserve_in as u128) * (FEE_SCALE as u128)) + coin_in_val_after_fees;

        // Multiply coin_in by the current exchange rate:
        // current_exchange_rate = reserve_out / reserve_in
        // amount_in_after_fees * current_exchange_rate -> amount_out
        math::mul_div_u128(
            coin_in_val_after_fees, // scaled to 1000
            (reserve_out as u128),
            new_reserve_in // scaled to 1000
        )
    }

    public fun assert_lp_value_is_increased(
        old_reserve_in: u64,
        old_reserve_out: u64,
        new_reserve_in: u64,
        new_reserve_out: u64
    ) {
        // never overflow
        assert!(
            (old_reserve_in as u128) * (old_reserve_out as u128)
                < (new_reserve_in as u128) * (new_reserve_out as u128),
            ERR_INCORRECT_SWAP
        )
    }

    // public(friend) fun swap<X, Y>(
    //     _account: &signer,
    //     _coin_in_value: u64,
    //     _coin_out_min_value: u64,
    //     _reserve_in: u64,
    //     _reserve_out: u64,
    // ) {
    //     abort ERR_DEPRECATED_FUNCTION
    // }
    public(friend) fun swap(
        user: &signer,
        in_meta: Object<Metadata>,
        out_meta: Object<Metadata>,
        coin_in_value: u64,
        coin_out_min_value: u64
    ) acquires LiquidityPool, Config {
        // Locate the pool for (in_meta, out_meta)
        let pair_addr = get_pair_address(in_meta, out_meta);
        assert!(exists<LiquidityPool>(pair_addr), ERR_POOL_DOES_NOT_EXIST);
        let pool = borrow_global_mut<LiquidityPool>(pair_addr);

        // Read live reserves
        let reserve_in = primary_fungible_store::balance(pair_addr, in_meta);
        let reserve_out = primary_fungible_store::balance(pair_addr, out_meta);

        let fee_multiplier = FEE_MULTIPLIER / 5; // 20% of swap fee to foundation
        let fee_value = math::mul_div(coin_in_value, fee_multiplier, FEE_SCALE);
        let out_val = get_amount_out(coin_in_value, reserve_in, reserve_out);
        assert!(
            out_val >= coin_out_min_value, ERR_COIN_OUT_NUM_LESS_THAN_EXPECTED_MINIMUM
        );

        let fee_acc = fee_account();
        let fee_addr = signer::address_of(&fee_acc);

        // Fee to fee account; net to pair account
        primary_fungible_store::transfer(user, in_meta, fee_addr, fee_value);
        primary_fungible_store::transfer(
            user,
            in_meta,
            pair_addr,
            coin_in_value - fee_value
        );

        // Pay out from pair -> user
        let pair_signer = account::create_signer_with_capability(&pool.pair_cap);
        let user_addr = signer::address_of(user);
        primary_fungible_store::transfer(&pair_signer, out_meta, user_addr, out_val);

        // Invariant (k increases due to truncation)
        let new_in = primary_fungible_store::balance(pair_addr, in_meta);
        let new_out = primary_fungible_store::balance(pair_addr, out_meta);
        // The division operation truncates the decimal,
        // Causing coin_out_value to be less than the calculated value.
        // Thus making the actual value of new_reserve_out.
        // So lp_value is increased.
        assert_lp_value_is_increased(reserve_in, reserve_out, new_in, new_out);

        update_oracle(pair_addr, pool);
        event::swapped_event(
            pool_address(),
            in_meta,
            out_meta,
            coin_in_value,
            out_val
        );
    }

    // public(friend) fun swap_out_y<X, Y>(
    //     account: &signer,
    //     coin_in_value: u64,
    //     coin_out_min_value: u64,
    //     reserve_in: u64,
    //     reserve_out: u64,
    // ) acquires LiquidityPool, Config {
    //     let fee_multiplier = FEE_MULTIPLIER / 5; // 20% fee to swap fundation.
    //     let fee_value = math::mul_div(coin_in_value, fee_multiplier, FEE_SCALE);
    //
    //     let coin_out_value = get_amount_out(coin_in_value, reserve_in, reserve_out);
    //     assert!(coin_out_value >= coin_out_min_value, ERR_COIN_OUT_NUM_LESS_THAN_EXPECTED_MINIMUM, );
    //
    //     let pool_address = pool_address();
    //     assert!(exists<LiquidityPool<X, Y>>(pool_address), ERR_POOL_DOES_NOT_EXIST);
    //     let pool = borrow_global_mut<LiquidityPool<X, Y>>(pool_address);
    //
    //     let coin_in = coin::withdraw<X>(account, coin_in_value);
    //
    //     let fee_in = coin::extract(&mut coin_in, fee_value);
    //     coin::deposit(fee_address(), fee_in);
    //
    //     coin::merge(&mut pool.coin_x, coin_in);
    //
    //     let out_swapped = coin::extract(&mut pool.coin_y, coin_out_value);
    //     coin::deposit(signer::address_of(account), out_swapped);
    //
    //     let new_reserve_in = coin::value<X>(&pool.coin_x);
    //     let new_reserve_out = coin::value<Y>(&pool.coin_y);
    //
    //     // The division operation truncates the decimal,
    //     // Causing coin_out_value to be less than the calculated value.
    //     // Thus making the actual value of new_reserve_out.
    //     // So lp_value is increased.
    //     assert_lp_value_is_increased(
    //         reserve_in,
    //         reserve_out,
    //         new_reserve_in,
    //         new_reserve_out
    //     );
    //
    //     event::swapped_event<X, Y>(pool_address, coin_in_value, coin_out_value);
    //     update_oracle<X, Y>(pool_address, pool)
    // }
    //
    // public(friend) fun swap_out_x<X, Y>(
    //     account: &signer,
    //     coin_in_value: u64,
    //     coin_out_min_value: u64,
    //     reserve_in: u64,
    //     reserve_out: u64,
    // ) acquires LiquidityPool, Config {
    //     let fee_multiplier = FEE_MULTIPLIER / 5; // 20% fee to swap fundation.
    //     let fee_value = math::mul_div(coin_in_value, fee_multiplier, FEE_SCALE);
    //
    //     let coin_out_value = get_amount_out(coin_in_value, reserve_in, reserve_out);
    //     assert!(coin_out_value >= coin_out_min_value, ERR_COIN_OUT_NUM_LESS_THAN_EXPECTED_MINIMUM, );
    //
    //     let pool_address = pool_address();
    //     assert!(exists<LiquidityPool<X, Y>>(pool_address), ERR_POOL_DOES_NOT_EXIST);
    //     let pool = borrow_global_mut<LiquidityPool<X, Y>>(pool_address);
    //
    //     let coin_in = coin::withdraw<Y>(account, coin_in_value);
    //
    //     let fee_in = coin::extract(&mut coin_in, fee_value);
    //     coin::deposit(fee_address(), fee_in);
    //
    //     coin::merge(&mut pool.coin_y, coin_in);
    //
    //     let out_swapped = coin::extract(&mut pool.coin_x, coin_out_value);
    //     coin::deposit(signer::address_of(account), out_swapped);
    //
    //     let new_reserve_in = coin::value<Y>(&pool.coin_y);
    //     let new_reserve_out = coin::value<X>(&pool.coin_x);
    //
    //     // The division operation truncates the decimal,
    //     // Causing coin_out_value to be less than the calculated value.
    //     // Thus making the actual value of new_reserve_out.
    //     // So lp_value is increased.
    //     assert_lp_value_is_increased(
    //         reserve_in,
    //         reserve_out,
    //         new_reserve_in,
    //         new_reserve_out
    //     );
    //
    //     event::swapped_event<X, Y>(pool_address, coin_in_value, coin_out_value);
    //     update_oracle<X, Y>(pool_address, pool)
    // }
    public fun update_oracle(
        pool_addr: address, pool: &mut LiquidityPool
    ) acquires Config {
        let x_reserve = primary_fungible_store::balance(pool_addr, pool.x_meta);
        let y_reserve = primary_fungible_store::balance(pool_addr, pool.y_meta);

        let last = pool.timestamp;
        let now = timestamp::now_seconds();
        let dt = now - last;

        if (dt > 0 && x_reserve != 0 && y_reserve != 0) {
            pool.x_cumulative = (dt as u128) * (x_reserve as u128) / (y_reserve as u128);
            pool.y_cumulative = (dt as u128) * (y_reserve as u128) / (x_reserve as u128);

            event::update_oracle_event(
                pool_address(),
                pool.x_meta,
                pool.y_meta,
                pool.x_cumulative,
                pool.y_cumulative
            );
        };
        pool.timestamp = now;
    }

    // fun update_oracle<X, Y>(
    //     pool_address: address,
    //     pool: &mut LiquidityPool<X, Y>,
    // ) {
    //     let x_reserve = coin::value(&pool.coin_x);
    //     let y_reserve = coin::value(&pool.coin_y);
    //
    //     let last_block_timestamp = pool.timestamp;
    //     let block_timestamp = timestamp::now_seconds();
    //     let time_elapsed = block_timestamp - last_block_timestamp;
    //
    //     if (time_elapsed > 0 && x_reserve != 0 && y_reserve != 0) {
    //         pool.x_cumulative = (time_elapsed as u128) * (x_reserve as u128) / (y_reserve as u128);
    //         pool.y_cumulative = (time_elapsed as u128) * (y_reserve as u128) / (x_reserve as u128);
    //
    //         event::update_oracle_event<X, Y>(pool_address, pool.x_cumulative, pool.y_cumulative);
    //     };
    //
    //     pool.timestamp = block_timestamp;
    // }
    public(friend) fun withdraw_fee(
        metadata: Object<Metadata>, beneficiary_addr: address
    ) acquires Config {
        let fee_acc = fee_account();
        let fee_addr = signer::address_of(&fee_acc);
        let total = primary_fungible_store::balance(fee_addr, metadata);
        if (total > 0) {
            primary_fungible_store::transfer(&fee_acc, metadata, beneficiary_addr, total);
        };
        event::withdrew_event(pool_address(), metadata, total)
    }

    // public(friend) fun withdraw_fee<Coin>(
    //     account: address
    // ) acquires Config {
    //     let fee_account = fee_account();
    //     let fee_address = signer::address_of(&fee_account);
    //
    //     let total = coin::balance<Coin>(fee_address);
    //     coin::transfer<Coin>(&fee_account, account, total);
    //
    //     event::withdrew_event<Coin>(pool_address(), total)
    // }

    /// Return amount of liquidity (LP) need for `coin_in`.
    /// * `coin_in` - amount to swap.
    /// * `reserve_in` - reserves of coin to swap.
    /// * `reserve_out` - reserves of coin to get.
    public fun convert_with_current_price(
        coin_in: u64, reserve_in: u64, reserve_out: u64
    ): u64 {
        assert!(coin_in > 0, ERR_WRONG_AMOUNT);
        assert!(
            reserve_in > 0 && reserve_out > 0,
            ERR_WRONG_RESERVE
        );

        // exchange_price = reserve_out / reserve_in_size
        // amount_returned = coin_in_val * exchange_price
        let res = math::mul_div(coin_in, reserve_out, reserve_in);
        (res as u64)
    }

    /// Calculate amounts needed for adding new liquidity for both `X` and `Y`.
    /// * `x_desired` - desired value of coins `X`.
    /// * `y_desired` - desired value of coins `Y`.
    /// Returns both `X` and `Y` coins amounts.
    public fun calc_optimal_coin_values(
        x_meta: Object<Metadata>,
        y_meta: Object<Metadata>,
        x_desired: u64,
        y_desired: u64
    ): (u64, u64) acquires LiquidityPool, Config {
        // 1) Determine the pair's storage account
        let pair_addr = get_pair_address(x_meta, y_meta);
        assert!(exists<LiquidityPool>(pair_addr), ERR_POOL_DOES_NOT_EXIST);

        // 2) Load reserves
        let pool = borrow_global<LiquidityPool>(pair_addr);
        let reserves_x = primary_fungible_store::balance(pair_addr, pool.x_meta);
        let reserves_y = primary_fungible_store::balance(pair_addr, pool.y_meta);

        // 3) First liquidity?
        if (reserves_x == 0 && reserves_y == 0) {
            (x_desired, y_desired)
        } else {
            let y_opt = convert_with_current_price(x_desired, reserves_x, reserves_y);
            if (y_opt <= y_desired) {
                (x_desired, y_opt)
            } else {
                let x_opt = convert_with_current_price(y_desired, reserves_y, reserves_x);
                assert!(x_opt <= x_desired, ERR_OVERLIMIT_X);
                (x_opt, y_desired)
            }
        }
    }
    /// Orders two FA metadata objects deterministically and return
s:
    /// - (asset_a, asset_b) in sorted order
    /// - seed vector<u8> for resource account derivation: b"swap:" || addr_a || b":" || addr_b
    public fun order_and_make_seed(
        x_meta: &object::Object<fungible_asset::Metadata>,
        y_meta: &object::Object<fungible_asset::Metadata>
    ): (
        object::Object<fungible_asset::Metadata>,
        object::Object<fungible_asset::Metadata>,
        vector<u8>
    ) {
        let xa = bcs::to_bytes(&object::object_address(x_meta));
        let ya = bcs::to_bytes(&object::object_address(y_meta));

        let cmp = aptos_std::comparator::compare(&xa, &ya);

        let (asset_a, asset_b, addr_a, addr_b) =
            if (cmp.is_smaller_than()) {
                (*x_meta, *y_meta, xa, ya)
            } else {
                (*y_meta, *x_meta, ya, xa)
            };

        let seed = vector::empty<u8>();
        vector::append(&mut seed, b"swap:");
        vector::append(&mut seed, addr_a);
        vector::push_back(&mut seed, 58u8);
        vector::append(&mut seed, addr_b);

        (asset_a, asset_b, seed)
    }

    public fun get_pair_address(
        x_meta: Object<Metadata>, y_meta: Object<Metadata>
    ): address acquires Config {
        let admin_addr =
            account::get_signer_capability_address(&borrow_global<Config>(@swap).pool_cap);
        let (asset_a, asset_b, seed) = order_and_make_seed(&x_meta, &y_meta);
        account::create_resource_address(&admin_addr, seed)
    }
    #[test_onl
y]
    public fun initialize_swap_for_test(
        swap_admin: &signer,
        controller: address,
        beneficiary: address
    ) {
        let (pool_account, pool_cap) =
            account::create_resource_account(swap_admin, b"swap_account_seed");
        let (_signer, fee_cap) =
            account::create_resource_account(swap_admin, b"fee_account_seed");

        move_to(
            swap_admin,
            Config { pool_cap, fee_cap, controller, beneficiary }
        );

        event::initialize(&pool_account);
    }
}
