// Copyright 2022 OmniBTC Authors. Licensed under Apache-2.0 License.
// Modifications copyright 2025 Devermint
#[test_only]
module swap::interface_tests {
    use std::option;
    use std::signer;
    use std::string::{Self, utf8};
    use std::bcs;
    use std::debug;

    use aptos_framework::account;
    use aptos_framework::genesis;

    use aptos_framework::object::{Self, Object};
    use aptos_framework::fungible_asset::{
        Self, Metadata, FungibleAsset, MintRef, TransferRef
    };
    use aptos_framework::primary_fungible_store;

    use aptos_std::comparator;

    use swap::implements;
    use swap::interface;
    use swap::math;

    const MAX_U64: u64 = 18446744073709551615;

    /**********************
     * FA test helpers
     **********************/

    /// Create a new FA metadata object with primary-store-enabled transfers,
    /// and return its `Object<Metadata>` plus mint & transfer refs.
    #[test_only]
    fun mk_fa(
        admin: &signer,
        name: vector<u8>,
        symbol: vector<u8>,
        decimals: u8
    ): (Object<Metadata>, MintRef, TransferRef) {
        let owner = signer::address_of(admin);
        let ctor = object::create_sticky_object(owner);

        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            &ctor,
            option::none<u128>(),
            utf8(name),
            utf8(symbol),
            decimals,
            utf8(b""),
            utf8(b"")
        );

        let mint_ref = fungible_asset::generate_mint_ref(&ctor);
        let transfer_ref = fungible_asset::generate_transfer_ref(&ctor);
        let meta_signer = object::generate_signer(&ctor);
        let meta = object::address_to_object<Metadata>(signer::address_of(&meta_signer));
        (meta, mint_ref, transfer_ref)
    }

    /// Mint `amount` of `meta` to `to` address.
    #[test_only]
    fun mint_to(
        meta: Object<Metadata>,
        mint_ref: &MintRef,
        xfer_ref: &TransferRef,
        to: address,
        amount: u64
    ) {
        let _ = primary_fungible_store::ensure_primary_store_exists(to, meta);
        let fa = fungible_asset::mint(mint_ref, amount);
        let store = primary_fungible_store::primary_store(to, meta);
        fungible_asset::deposit_with_ref(xfer_ref, store, fa);
    }

    // #[inline]
    fun bal(addr: address, meta: Object<Metadata>): u64 {
        primary_fungible_store::balance(addr, meta)
    }

    /// Return (reserve_in, reserve_out) oriented to a given swap direction.
    /// This is needed because pool stores (x,y) in sorted metadata-address order.
    #[test_only]
    fun reserves_for_direction(
        pool_x: Object<Metadata>,
        pool_y: Object<Metadata>,
        in_meta: Object<Metadata>,
        out_meta: Object<Metadata>
    ): (u64, u64) {
        let (r_a, r_b) = implements::get_reserves_size(pool_x, pool_y);

        let ax = object::object_address(&pool_x);
        let ay = object::object_address(&pool_y);
        let ai = object::object_address(&in_meta);
        let ao = object::object_address(&out_meta);

        // Determine which of (r_a, r_b) corresponds to (ai, ao)
        let cmp_xy = comparator::compare(&bcs::to_bytes(&ax), &bcs::to_bytes(&ay));
        let (sorted0, sorted1) = if (cmp_xy.is_smaller_than()) { (ax, ay) } else { (ay, ax) };

        if (sorted0 == ai && sorted1 == ao) {
            (r_a, r_b)
        } else {
            // Either reversed direction or caller passed metas in any order.
            (r_b, r_a)
        }
    }

    /********************************************
     * Test-time pool bootstrap (FA version)
     ********************************************/
    #[test_only]
    fun register_pool_with_liquidity(
        account_ref: &signer, usdt_val: u64, xbtc_val: u64
    ) {
        genesis::setup();

        let admin = account::create_account_for_test(@swap);
        let user_addr = signer::address_of(account_ref);
        let admin_addr = signer::address_of(&admin);

        // Create FA metas for XBTC & USDT under admin
        let (xbtc_meta, x_mint, x_xfer) = mk_fa(&admin, b"XBTC", b"XBTC", 8);
        let (usdt_meta, u_mint, u_xfer) = mk_fa(&admin, b"USDT", b"USDT", 8);

        // Fund user & admin with balances
        mint_to(usdt_meta, &u_mint, &u_xfer, user_addr, usdt_val);
        mint_to(usdt_meta, &u_mint, &u_xfer, admin_addr, usdt_val);
        mint_to(xbtc_meta, &x_mint, &x_xfer, user_addr, xbtc_val);
        mint_to(xbtc_meta, &x_mint, &x_xfer, admin_addr, xbtc_val);

        // Initialize swap config (test-only entry)
        implements::initialize_swap_for_test(&admin, admin_addr, admin_addr);

        // Register pool & add initial liquidity from admin
        interface::register_pool(&admin, xbtc_meta, usdt_meta);
        interface::add_liquidity(&admin, usdt_meta, xbtc_meta, usdt_val, 1, xbtc_val, 1);

        // Admin used all supplied balances
        assert!(bal(admin_addr, usdt_meta) == 0, 5);
        assert!(bal(admin_addr, xbtc_meta) == 0, 6);
    }

    /**********************
     * Tests
     **********************/

    #[
        test(
            swap_admin = @swap,
            expected_address =
            @0x91d9739d38da9ac1a50aa64c07ff70f62fc46850c3f9a5b44f6adfcb7c76a9b
        )
    ]
    fun test_swap_pool_account(
        swap_admin: &signer, expected_address: address
    ) {
        let (pool_account, _pool_cap) =
            account::create_resource_account(swap_admin, b"swap_account_seed");

        assert!(expected_address == signer::address_of(&pool_account), 1)
    }

    #[test]
    fun test_generate_lp_name_and_symbol() {
        genesis::setup();
        let admin = account::create_account_for_test(@swap);

        let (xbtc_meta, _, _) = mk_fa(&admin, b"XBTC", b"XBTC", 8);
        let (usdt_meta, _, _) = mk_fa(&admin, b"USDT", b"USDT", 8);
        let (apt_meta,  _, _) = mk_fa(&admin, b"APT",  b"APT",  8);

        let (lp_name, lp_symbol) = implements::generate_lp_name_and_symbol(xbtc_meta, usdt_meta);
        assert!(lp_name == utf8(b"LP-XBTC-USDT"), 0);
        assert!(lp_symbol == utf8(b"XBTC-USDT"), 0);

        let (lp_name2, lp_symbol2) = implements::generate_lp_name_and_symbol(apt_meta, usdt_meta);
        assert!(lp_name2 == utf8(b"LP-APT-USDT"), 0);
        assert!(lp_symbol2 == utf8(b"APT-USDT"), 0);
    }

    #[test]
    fun test_initialize_swap() {
        genesis::setup();

        let swap_admin = account::create_account_for_test(@swap);
        interface::initialize_swap(
            &swap_admin,
            signer::address_of(&swap_admin),
            signer::address_of(&swap_admin)
        );
    }

    #[test]
    fun test_register_pool() {
        genesis::setup();
        let admin = account::create_account_for_test(@swap);

        let (xbtc_meta, _, _) = mk_fa(&admin, b"XBTC", b"XBTC", 8);
        let (usdt_meta, _, _) = mk_fa(&admin, b"USDT", b"USDT", 8);

        interface::initialize_swap(
            &admin,
            signer::address_of(&admin),
            signer::address_of(&admin)
        );

        interface::register_pool(&admin, xbtc_meta, usdt_meta);
    }

    #[test]
    fun test_add_liquidity() {
        genesis::setup();
        let admin = account::create_account_for_test(@swap);

        let (xbtc_meta, x_mint, x_xfer) = mk_fa(&admin, b"XBTC", b"XBTC", 8);
        let (usdt_meta, u_mint, u_xfer) = mk_fa(&admin, b"USDT", b"USDT", 8);

        let x_val = 200000000;
        let u_val = 2000000000000;

        mint_to(xbtc_meta, &x_mint, &x_xfer, signer::address_of(&admin), x_val);
        mint_to(usdt_meta, &u_mint, &u_xfer, signer::address_of(&admin), u_val);

        interface::initialize_swap(
            &admin,
            signer::address_of(&admin),
            signer::address_of(&admin)
        );

        assert!(!implements::is_pool_exists(usdt_meta, xbtc_meta), 1);

        interface::add_liquidity(&admin, xbtc_meta, usdt_meta, x_val, 1000, u_val, 1000);

        assert!(implements::is_pool_exists(usdt_meta, xbtc_meta), 2);
    }

    #[test]
    fun test_remove_liquidity() {
        genesis::setup();
        let admin = account::create_account_for_test(@swap);

        let (xbtc_meta, x_mint, x_xfer) = mk_fa(&admin, b"XBTC", b"XBTC", 8);
        let (usdt_meta, u_mint, u_xfer) = mk_fa(&admin, b"USDT", b"USDT", 8);

        let x_val = 200000000;
        let u_val = 2000000000000;

        let admin_addr = signer::address_of(&admin);
        mint_to(xbtc_meta, &x_mint, &x_xfer, admin_addr, x_val);
        mint_to(usdt_meta, &u_mint, &u_xfer, admin_addr, u_val);

        interface::initialize_swap(
            &admin,
            admin_addr,
            admin_addr
        );

        interface::register_pool(&admin, xbtc_meta, usdt_meta);
        interface::add_liquidity(&admin, usdt_meta, xbtc_meta, u_val, 1000, x_val, 1000);

        // Burn a portion of LP; assert balances increase and reserves drop.
        let (ru_before, rx_before) = implements::get_reserves_size(usdt_meta, xbtc_meta);
        let u_before = bal(admin_addr, usdt_meta);
        let x_before = bal(admin_addr, xbtc_meta);

        interface::remove_liquidity(&admin, usdt_meta, xbtc_meta, 200000, 1000, 1000);

        let (ru_after, rx_after) = implements::get_reserves_size(usdt_meta, xbtc_meta);
        let u_after = bal(admin_addr, usdt_meta);
        let x_after = bal(admin_addr, xbtc_meta);

        assert!(ru_after < ru_before, 1);
        assert!(rx_after < rx_before, 2);
        assert!(u_after > u_before, 3);
        assert!(x_after > x_before, 4);
    }

    // Intentionally not annotated with #[test] in the original file; keep parity.
    fun test_swap() {
        genesis::setup();
        let admin = account::create_account_for_test(@swap);

        let (xbtc_meta, x_mint, x_xfer) = mk_fa(&admin, b"XBTC", b"XBTC", 8);
        let (usdt_meta, u_mint, u_xfer) = mk_fa(&admin, b"USDT", b"USDT", 8);

        let x_val = 200000000;
        let u_val = 2000000000000;

        let admin_addr = signer::address_of(&admin);
        mint_to(xbtc_meta, &x_mint, &x_xfer, admin_addr, x_val);
        mint_to(usdt_meta, &u_mint, &u_xfer, admin_addr, u_val);

        interface::initialize_swap(
            &admin,
            admin_addr,
            admin_addr
        );

        interface::register_pool(&admin, xbtc_meta, usdt_meta);
        interface::add_liquidity(&admin, usdt_meta, xbtc_meta, u_val - 30000000, 1000, x_val, 1000);

        interface::swap(&admin, usdt_meta, xbtc_meta, 100000, 1);
    }

    #[test(user = @0x123)]
fun test_add_liquidity_with_value(user: address) {
    genesis::setup();
    let admin = account::create_account_for_test(@swap);
    let admin_addr = signer::address_of(&admin);
    let user_account = account::create_account_for_test(user);

    let usdt_val = 1900000000000;
    let xbtc_val = 100000000;

    // Create actual pool assets
    let (mx, m_mint, m_xfer) = mk_fa(&admin, b"UXBTC", b"UXBTC", 8);
    let (mu, u_mint, u_xfer) = mk_fa(&admin, b"UUSDT", b"UUSDT", 8);

    // Fund user
    mint_to(mu, &u_mint, &u_xfer, user, usdt_val);
    mint_to(mx, &m_mint, &m_xfer, user, xbtc_val);

    // Init swap + register pool
    implements::initialize_swap_for_test(&admin, admin_addr, admin_addr);
    interface::register_pool(&admin, mu, mx);

    let u_before = bal(user, mu);
    let x_before = bal(user, mx);

    // Add liquidity using the exact same metas
    interface::add_liquidity(&user_account, mu, mx, usdt_val  / 100, 1, xbtc_val / 100, 1);

    let u_after = bal(user, mu);
    let x_after = bal(user, mx);

    assert!(u_after == u_before - usdt_val / 100, 1);
    assert!(x_after == x_before - xbtc_val / 100, 2);

    // Check pool reserves match what we just deposited
    let (r_a, r_b) = implements::get_reserves_size(mu, mx);
    assert!(
        (r_a == usdt_val / 100 && r_b == xbtc_val / 100) ||
        (r_a == xbtc_val / 100 && r_b == usdt_val / 100),
        3
    );
}

   #[test(user = @0x123)]
    fun test_remove_liquidity_with_value(user: address) {
        genesis::setup();
        let admin = account::create_account_for_test(@swap);
        let user_account = account::create_account_for_test(user);

        let usdt_val = 1900000000000;
        let xbtc_val = 100000000;

        let (mx, m_mint, m_xfer) = mk_fa(&user_account, b"UXBTC", b"UXBTC", 8);
        let (mu, u_mint, u_xfer) = mk_fa(&user_account, b"UUSDT", b"UUSDT", 8);

        mint_to(mu, &u_mint, &u_xfer, user, usdt_val);
        mint_to(mx, &m_mint, &m_xfer, user, xbtc_val);

        interface::initialize_swap(&admin, user, user);

        let usdt_liq = usdt_val / 100;
        let xbtc_liq = xbtc_val / 100;
        interface::add_liquidity(&user_account, mu, mx, usdt_liq, 1, xbtc_liq, 1);

        let (r_usdt, r_xbtc) = implements::get_reserves_size(mu, mx);
        assert!(
            (r_usdt == usdt_liq && r_xbtc == xbtc_liq) ||
            (r_usdt == xbtc_liq && r_xbtc == usdt_liq),
            100
        );

        let pair_addr = implements::get_pair_address(mu, mx);
        let pool_lp_meta = implements::get_lp_meta(pair_addr);
        let user_lp_bal = primary_fungible_store::balance(user, pool_lp_meta);
        assert!(user_lp_bal > 0, 101);

        let lp_to_burn = user_lp_bal / 10;

        let u_before = bal(user, mu);
        let x_before = bal(user, mx);
        let (ru_before, rx_before) = implements::get_reserves_size(mu, mx);

        interface::remove_liquidity(&user_account, mu, mx, lp_to_burn, 1, 1);

        let u_after = bal(user, mu);
        let x_after = bal(user, mx);
        let (ru_after, rx_after) = implements::get_reserves_size(mu, mx);

        assert!(u_after > u_before, 1);
        assert!(x_after > x_before, 2);
        assert!(ru_after < ru_before, 3);
        assert!(rx_after < rx_before, 4);
    }


    #[test(user = @0x123)]
    fun test_swap_with_value(user: address) {
        genesis::setup();
        let admin = account::create_account_for_test(@swap);
        let admin_addr = signer::address_of(&admin);
        let user_account = account::create_account_for_test(user);

        let usdt_val = 1900000000000;
        let xbtc_val = 100000000;

        // Build user's own assets/pool for deterministic metadata
        let (mx, m_mint, m_xfer) = mk_fa(&user_account, b"UXBTC", b"UXBTC", 8);
        let (mu, u_mint, u_xfer) = mk_fa(&user_account, b"UUSDT", b"UUSDT", 8);
        mint_to(mu, &u_mint, &u_xfer, user, usdt_val);
        mint_to(mx, &m_mint, &m_xfer, user, xbtc_val);
        mint_to(mu, &u_mint, &u_xfer, admin_addr, usdt_val);
        mint_to(mx, &m_mint, &m_xfer, admin_addr, xbtc_val);

        interface::initialize_swap(&admin, user, user);
        interface::add_liquidity(&admin, mu, mx, usdt_val / 100, 1, xbtc_val / 100, 1);

        let u_before = bal(user, mu);
        let x_before = bal(user, mx);

        let (reserve_in, reserve_out) = reserves_for_direction(mu, mx, mu, mx);
        let expected_xbtc = implements::get_amount_out(usdt_val / 100, reserve_in, reserve_out);

        interface::swap(&user_account, mu, mx, usdt_val / 100, 1);

        assert!(bal(user, mu) == u_before - usdt_val / 100, bal(user, mu));
        assert!(bal(user, mx) == x_before + expected_xbtc, bal(user, mx));
    }

    #[test(user = @0x123)]
    fun test_get_amount_out_does_not_overflow_on_liquidity_close_to_max_pool_value(
        user: address
    ) {
        genesis::setup();
        let admin = account::create_account_for_test(@swap);
        let admin_addr = signer::address_of(&admin);
        let user_account = account::create_account_for_test(user);
        let usdt_val = MAX_U64 / 20000;
        let xbtc_val = MAX_U64 / 20000;

        let (mx, m_mint, m_xfer) = mk_fa(&user_account, b"UXBTC", b"UXBTC", 8);
        let (mu, u_mint, u_xfer) = mk_fa(&user_account, b"UUSDT", b"UUSDT", 8);
        mint_to(mu, &u_mint, &u_xfer, user, usdt_val);
        mint_to(mx, &m_mint, &m_xfer, user, xbtc_val);

        interface::initialize_swap(&admin, user, user);
        interface::add_liquidity(&user_account, mu, mx, usdt_val, 1, xbtc_val, 1);
    }

    #[test(user = @0x123)]
    fun test_get_amount_out_does_not_overflow_on_coin_in_close_to_u64_max(
        user: address
    ) {
        genesis::setup();
        let admin = account::create_account_for_test(@swap);
        let admin_addr = signer::address_of(&admin);
        let user_account = account::create_account_for_test(user);
        let usdt_val = MAX_U64 / 20000;
        let xbtc_val = MAX_U64 / 20000;
        let max_usdt = MAX_U64;

        let (mx, m_mint, m_xfer) = mk_fa(&user_account, b"UXBTC", b"UXBTC", 8);
        let (mu, u_mint, u_xfer) = mk_fa(&user_account, b"UUSDT", b"UUSDT", 8);
        mint_to(mu, &u_mint, &u_xfer, user, usdt_val);
        mint_to(mx, &m_mint, &m_xfer, user, xbtc_val);

        interface::initialize_swap(&admin, user, user);
        interface::add_liquidity(&user_account, mu, mx, usdt_val, 1, xbtc_val, 1);

        let (reserve_usdt, reserve_xbtc) = reserves_for_direction(mu, mx, mu, mx);
        let _expected_xbtc = implements::get_amount_out(max_usdt, reserve_usdt, reserve_xbtc);
    }

    #[test(user = @0x123)]
    #[expected_failure(abort_code = 314)]
    fun test_add_liquidity_aborts_if_pool_has_full(user: address) {
        let user_account = account::create_account_for_test(user);
        let usdt_val = MAX_U64 / 10000;
        let xbtc_val = MAX_U64 / 10000;

        let (mx, m_mint, m_xfer) = mk_fa(&user_account, b"UXBTC", b"UXBTC", 8);
        let (mu, u_mint, u_xfer) = mk_fa(&user_account, b"UUSDT", b"UUSDT", 8);
        mint_to(mu, &u_mint, &u_xfer, user, usdt_val);
        mint_to(mx, &m_mint, &m_xfer, user, xbtc_val);

        // interface::initialize_swap(&admin, user, user);
        // Should abort with ERR_POOL_FULL (314)
        register_pool_with_liquidity(&user_account, usdt_val, xbtc_val);
    }

    #[test(user = @0x123)]
    fun test_swap_with_value_should_ok(user: address) {
        genesis::setup();
        let admin = account::create_account_for_test(@swap);
        let user_account = account::create_account_for_test(user);
        let admin_addr = signer::address_of(&admin);

        let usdt_val = 184456367;
        let xbtc_val = 70100;

        // Metas + caps are created under user_account in your mk_fa; that's fine.
        let (mx, m_mint, m_xfer) = mk_fa(&user_account, b"UXBTC", b"UXBTC", 8);
        let (mu, u_mint, u_xfer) = mk_fa(&user_account, b"UUSDT", b"UUSDT", 8);

        // Fund BOTH admin (LP provider) and user (swapper).
        mint_to(mu, &u_mint, &u_xfer, admin_addr, usdt_val);
        mint_to(mx, &m_mint, &m_xfer, admin_addr, xbtc_val);
        mint_to(mu, &u_mint, &u_xfer, user, usdt_val);
        mint_to(mx, &m_mint, &m_xfer, user, xbtc_val);

        interface::initialize_swap(&admin, user, user);

        // Admin seeds the pool; user keeps their balances.
        interface::add_liquidity(&admin, mu, mx, usdt_val, 1, xbtc_val, 1);

        // Rest of your test unchanged…
        let (r1, r2) = implements::get_reserves_size(mu, mx);
        assert!((r1 == usdt_val && r2 == xbtc_val) || (r1 == xbtc_val && r2 == usdt_val), r1);

        let (reserve_in, reserve_out) = reserves_for_direction(mu, mx, mu, mx);
        let expected_btc = implements::get_amount_out(usdt_val, reserve_in, reserve_out);
        assert!(34997 == expected_btc, expected_btc);

        interface::swap(&user_account, mu, mx, usdt_val, 1);

        let fee_value = math::mul_div(usdt_val, 6, 10000);
        let expected_in_after = reserve_in + (usdt_val - fee_value);
        let expected_out_after = reserve_out - expected_btc;

        let (_ra, _rb) = implements::get_reserves_size(mu, mx);
        let (actual_in_after, actual_out_after) = reserves_for_direction(mu, mx, mu, mx);
        assert!(expected_in_after == actual_in_after, actual_in_after);
        assert!(expected_out_after == actual_out_after, actual_out_after);

        assert!(bal(user, mx) == xbtc_val + expected_btc, bal(user, mx));
        assert!(bal(user, mu) == 0, bal(user, mu));

        let (reserve_in2, reserve_out2) = reserves_for_direction(mu, mx, mx, mu);
        let expected_usdt = implements::get_amount_out(xbtc_val, reserve_in2, reserve_out2);
        assert!(245497690 == expected_usdt, expected_usdt);

        interface::swap(&user_account, mx, mu, xbtc_val, 1);
        assert!(bal(user, mx) == expected_btc, bal(user, mx));
        assert!(bal(user, mu) == expected_usdt, bal(user, mu));
    }

}
