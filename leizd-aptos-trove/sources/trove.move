module leizd_aptos_trove::trove {
    use std::error;
    use std::signer;
    use aptos_std::event;
    use aptos_framework::account;
    use aptos_framework::coin;
    use leizd_aptos_lib::math128;
    use leizd_aptos_common::permission;
    use leizd_aptos_trove::usdz;
    use leizd_aptos_external::price_oracle;

    friend leizd_aptos_trove::trove_manager;

    const ENOT_SUPPORTED: u64 = 1;
    const EALREADY_SUPPORTED: u64 = 2;

    struct Trove<phantom C> has key, store {
        coin: coin::Coin<C>
    }

    struct SupportedCoin<phantom C> has key {}

    struct OpenTroveEvent has store, drop {
        caller: address,
        amount: u64,
        collateral_amount: u64,
    }

    struct CloseTroveEvent has store, drop {
        caller: address,
    }

    struct RepayEvent has store, drop {
        caller: address,
        amount: u64,
        collateral_amount: u64,
    }

    struct TroveEventHandle<phantom C> has key, store {
        open_trove_event: event::EventHandle<OpenTroveEvent>,
        close_trove_event: event::EventHandle<CloseTroveEvent>,
        repay_event: event::EventHandle<RepayEvent>,
    }
    
    public(friend) fun initialize(owner: &signer) {
        initialize_internal(owner);
    }

    fun initialize_internal(owner: &signer) {
        usdz::initialize(owner);
    }

    public(friend) fun add_supported_coin<C>(owner: &signer) {
        add_supported_coin_internal<C>(owner);
    }

    fun add_supported_coin_internal<C>(owner: &signer) {
        permission::assert_owner(signer::address_of(owner));
        assert!(!is_coin_supported<C>(), error::invalid_argument(EALREADY_SUPPORTED));
        move_to(owner, SupportedCoin<C> {});
        move_to(owner, TroveEventHandle<C> {
            open_trove_event: account::new_event_handle<OpenTroveEvent>(owner),
            close_trove_event: account::new_event_handle<CloseTroveEvent>(owner),
            repay_event: account::new_event_handle<RepayEvent>(owner),
        })
    }

    public fun trove_amount<C>(account: address): u64 acquires Trove {
        if(!exists<Trove<C>>(account)) {
            return 0
        };
        let trove = borrow_global<Trove<C>>(account);
        coin::value<C>(&trove.coin)
    }
    

    public(friend) fun open_trove<C>(account: &signer, amount: u64) acquires Trove, TroveEventHandle {
        open_trove_internal<C>(account, amount, borrowable_usdz<C>(amount));
    }

    public(friend) fun redeem<C>(account: &signer, target_account: address, amount: u64) acquires Trove{
        redeem_internal<C>(account, target_account, amount)
    }

    fun redeem_internal<C>(account: &signer, target_account: address, amount: u64) acquires Trove {
        let target = borrow_global_mut<Trove<C>>(target_account);
        assert!(coin::value(&target.coin) >= amount, 0);
        usdz::burn(account, borrowable_usdz<C>(amount));
        let deposited = coin::extract(&mut target.coin, amount);
        coin::deposit<C>(signer::address_of(account), deposited);
    }

//    fun requireMaxFeePercentage(_input: RedeemInput){}
    fun requireAfterBootstrapPeriod() {}
    fun requireTCRoverMCR(_price: u64) {}
    fun requireAmountGreaterThanZero(_amount: u64) {}
    fun requireUSDZBalanceCoversRedemption() {}

    fun validate_open_trove<C>() {
        validate_internal<C>()
    }

    fun validate_close_trove<C>() {
        validate_internal<C>()
    }

    fun validate_repay<C>() {
        validate_internal<C>()
    }

    fun validate_internal<C>() {
        assert!(is_coin_supported<C>(), error::invalid_argument(ENOT_SUPPORTED))
    }

    fun is_coin_supported<C>(): bool {
        exists<SupportedCoin<C>>(permission::owner_address())
    }

    public(friend) fun close_trove<C>(account: &signer) acquires Trove, TroveEventHandle {
        close_trove_internal<C>(account);
    }

    public(friend) fun repay<C>(account: &signer, collateral_amount: u64) acquires Trove, TroveEventHandle {
        repay_internal<C>(account, collateral_amount);
    }

    fun borrowable_usdz<C>(amount: u64): u64 {
        let (price, _decimals) = price_oracle::price<C>();
        let decimals = (_decimals as u128);
        let decimals_usdz = (coin::decimals<usdz::USDZ>() as u128);

        let numerator = price * (amount as u128) * math128::pow(10, decimals_usdz);
        let dominator = (math128::pow(10, decimals * 2));
        (numerator / dominator as u64)
    }

    fun open_trove_internal<C>(account: &signer, collateral_amount: u64, amount: u64) acquires Trove, TroveEventHandle {
        let account_addr = signer::address_of(account);
        validate_open_trove<C>();
        let initialized = exists<Trove<C>>(account_addr);
        if (!initialized) {
            move_to(account, Trove<C> {
                coin: coin::zero<C>(),
            });
        };
        let trove = borrow_global_mut<Trove<C>>(account_addr);
        coin::merge(&mut trove.coin, coin::withdraw<C>(account, collateral_amount));
        usdz::mint(account, amount);
        event::emit_event<OpenTroveEvent>(
            &mut borrow_global_mut<TroveEventHandle<C>>(permission::owner_address()).open_trove_event,
            OpenTroveEvent {
                caller: account_addr,
                amount,
                collateral_amount
            },
        )
    }

    fun close_trove_internal<C>(account: &signer) acquires Trove, TroveEventHandle {
        validate_close_trove<C>();
        let trove = borrow_global_mut<Trove<C>>(signer::address_of(account));
        let balance = coin::value(&trove.coin);
        repay_internal<C>(account, balance);
        event::emit_event<CloseTroveEvent>(
            &mut borrow_global_mut<TroveEventHandle<C>>(permission::owner_address()).close_trove_event,
            CloseTroveEvent {
                caller: signer::address_of(account),
            },
        );
    }

    fun repay_internal<C>(account: &signer, collateral_amount: u64) acquires Trove, TroveEventHandle {
        validate_repay<C>();
        let trove = borrow_global_mut<Trove<C>>(signer::address_of(account));
        let amount = borrowable_usdz<C>(collateral_amount);
        usdz::burn(account, amount);
        coin::deposit<C>(signer::address_of(account), coin::extract(&mut trove.coin, collateral_amount));
        event::emit_event<RepayEvent>(
            &mut borrow_global_mut<TroveEventHandle<C>>(permission::owner_address()).repay_event,
            RepayEvent {
                caller: signer::address_of(account),
                amount,
                collateral_amount
            },
        );
    }

    #[test_only]
    use aptos_framework::managed_coin;
    #[test_only]
    use leizd_aptos_lib::math64;
    #[test_only]
    use leizd_aptos_common::test_coin::{Self,USDC,USDT};
    #[test_only]
    use aptos_std::comparator;

    #[test_only]
    fun set_up(owner: &signer, account1: &signer) {
        let owner_addr = signer::address_of(owner);
        let account1_addr = signer::address_of(account1);
        let amount = 10000;
        account::create_account_for_test(owner_addr);
        account::create_account_for_test(account1_addr);
        test_coin::init_usdc(owner);
        test_coin::init_usdt(owner);
        managed_coin::register<USDC>(account1);
        managed_coin::register<USDT>(account1);
        initialize_oracle(owner);
        managed_coin::register<usdz::USDZ>(account1);
        managed_coin::mint<USDC>(owner, account1_addr, amount);
        managed_coin::mint<USDT>(owner, account1_addr, amount);
        initialize_internal(owner);
        add_supported_coin_internal<USDC>(owner);
        add_supported_coin_internal<USDT>(owner);
    }

    #[test_only]
    fun initialize_oracle(owner: &signer) {
        price_oracle::initialize(owner);
        price_oracle::register_oracle_with_fixed_price<USDC>(owner, 1000000, 6, false);
        price_oracle::register_oracle_with_fixed_price<USDT>(owner, 1000000, 6, false);
        price_oracle::change_mode<USDC>(owner, 1);
        price_oracle::change_mode<USDT>(owner, 1);
    }

    #[test_only]
    fun initialize_oracle_coin<C>(owner: &signer, price: u128, decimals: u8) {
        price_oracle::register_oracle_with_fixed_price<C>(owner, price, decimals, false);
        price_oracle::change_mode<C>(owner, 1);
    }

    #[test(owner=@leizd_aptos_trove)]
    fun test_initialize(owner: &signer) {
        let owner_addr = signer::address_of(owner);
        account::create_account_for_test(owner_addr);
        initialize_internal(owner);
    }
    #[test(owner=@leizd_aptos_trove)]
    #[expected_failure(abort_code = 524290)]
    fun test_initialize_twice(owner: &signer) {
        let owner_addr = signer::address_of(owner);
        account::create_account_for_test(owner_addr);
        initialize_internal(owner);
        initialize_internal(owner);
    }
    #[test(account=@0x111)]
    #[expected_failure(abort_code = 65537)]
    fun test_initialize_with_not_owner(account: &signer) {
        initialize_internal(account);
    }
    #[test(owner=@leizd_aptos_trove)]
    fun test_add_supported_coin(owner: &signer) {
        let owner_addr = signer::address_of(owner);
        account::create_account_for_test(owner_addr);
        initialize_internal(owner);
        add_supported_coin_internal<USDC>(owner);
        assert!(exists<SupportedCoin<USDC>>(owner_addr), 0);
        assert!(exists<TroveEventHandle<USDC>>(owner_addr), 0);
    }
    #[test(owner=@leizd_aptos_trove)]
    #[expected_failure(abort_code = 65538)]
    fun test_add_supported_coin_twice(owner: &signer) {
        account::create_account_for_test(signer::address_of(owner));
        initialize_internal(owner);
        add_supported_coin_internal<USDC>(owner);
        add_supported_coin_internal<USDC>(owner);
    }
    #[test(owner=@leizd_aptos_trove, account = @0x111)]
    #[expected_failure(abort_code = 65537)]
    fun test_add_supported_coin_with_not_owner(owner: &signer, account: &signer) {
        account::create_account_for_test(signer::address_of(owner));
        initialize_internal(owner);
        add_supported_coin_internal<USDC>(account);
    }

    #[test(owner=@leizd_aptos_trove,account1=@0x111,aptos_framework=@aptos_framework)]
    fun test_open_trove(owner: signer, account1: signer) acquires Trove, TroveEventHandle {
        set_up(&owner, &account1);
        let account1_addr = signer::address_of(&account1);
        let usdc_amt = 10000;
        let want = usdc_amt * math64::pow(10, 8 - 6);
        open_trove<USDC>(&account1, 10000);
        assert!(comparator::is_equal(&comparator::compare(
            &usdz::balance_of(account1_addr),
            &want
        )), 0);
        assert!(coin::balance<USDC>(account1_addr) == 0, 0);
        // add more USDC
        managed_coin::mint<USDC>(&owner, account1_addr, 10000);
        open_trove<USDC>(&account1, 10000);
        assert!(comparator::is_equal(&comparator::compare(
            &usdz::balance_of(account1_addr),
            &(want * 2)
        )), 0);
        // add USDT
        open_trove<USDT>(&account1, 10000);
        assert!(comparator::is_equal(&comparator::compare(
            &usdz::balance_of(account1_addr),
            &(want * 3)
        )), 0);
    }
    #[test(owner=@leizd_aptos_trove,account=@0x111,aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 65537)]
    fun test_open_trove_before_add_supported_coin(owner: &signer, account: &signer) acquires Trove, TroveEventHandle {
        let owner_addr = signer::address_of(owner);
        let account_addr = signer::address_of(account);
        account::create_account_for_test(owner_addr);
        account::create_account_for_test(account_addr);
        test_coin::init_usdc(owner);
        managed_coin::register<usdz::USDZ>(account);
        managed_coin::register<USDC>(account);
        managed_coin::mint<USDC>(owner, account_addr, 10000);

        initialize_internal(owner);
        price_oracle::initialize(owner);
        price_oracle::register_oracle_with_fixed_price<USDC>(owner, 1000000, 6, false);
        price_oracle::change_mode<USDC>(owner, 1);
        open_trove<USDC>(account, 10000);
    }

    #[test(owner=@leizd_aptos_trove,account1=@0x111,aptos_framework=@aptos_framework)]
    fun test_close_trove(owner: signer, account1: signer) acquires Trove, TroveEventHandle {
        set_up(&owner, &account1);
        open_trove<USDC>(&account1, 10000);
        close_trove<USDC>(&account1);
        let account1_addr = signer::address_of(&account1);
        assert!(coin::balance<USDC>(account1_addr) == 10000, 0);
        let trove = borrow_global<Trove<USDC>>(account1_addr);
        assert!(coin::value(&trove.coin) == 0, 0);
    }    

    #[test(owner=@leizd_aptos_trove,account1=@0x111,aptos_framework=@aptos_framework)]
    fun test_repay(owner: signer, account1: signer) acquires Trove, TroveEventHandle {
        set_up(&owner, &account1);
        open_trove<USDC>(&account1, 10000);
        repay<USDC>(&account1, 5000);
        let account1_addr = signer::address_of(&account1);
        assert!(coin::balance<USDC>(account1_addr) == 5000, 0);
        let trove = borrow_global<Trove<USDC>>(account1_addr);
        assert!(coin::value(&trove.coin) == 5000, 0);
        // repay more
        repay<USDC>(&account1, 5000);
        assert!(coin::balance<USDC>(account1_addr) == 10000, 0);
        let trove2 = borrow_global<Trove<USDC>>(account1_addr);
        assert!(coin::value(&trove2.coin) == 0, 0);
    }

    #[test(owner=@leizd_aptos_trove,aptos_framework=@aptos_framework)]
    fun test_borrowable_usdz(owner: &signer) {
        account::create_account_for_test(signer::address_of(owner));
        test_coin::init_usdc(owner);
        initialize(owner);
        initialize_oracle(owner);

        let usdc_amt = 12345678;
        let usdc_want = usdc_amt * math64::pow(10, 8 - 6);
        assert!(comparator::is_equal(&comparator::compare(
            &borrowable_usdz<USDC>(usdc_amt),
            &usdc_want
        )), 0);
    }
    #[test_only]
    struct DummyCoin {}
    #[test(owner=@leizd_aptos_trove,aptos_framework=@aptos_framework)]
    fun test_borrowable_usdz__check_when_decimal_is_less_than_usdz(owner: &signer) {
        account::create_account_for_test(signer::address_of(owner));
        initialize(owner);
        initialize_oracle(owner);
        let decimals: u8 = 3;
        test_coin::init_coin<DummyCoin>(owner, b"DUMMY", decimals);
        initialize_oracle_coin<DummyCoin>(owner, 1000, decimals);

        let expected = 100000 * math64::pow(10, (coin::decimals<usdz::USDZ>() - decimals as u64));
        assert!(borrowable_usdz<DummyCoin>(100000) == expected, 0);
    }
    #[test(owner=@leizd_aptos_trove,aptos_framework=@aptos_framework)]
    fun test_borrowable_usdz__check_when_decimal_is_greater_than_usdz(owner: &signer) {
        account::create_account_for_test(signer::address_of(owner));
        initialize(owner);
        initialize_oracle(owner);
        let decimals: u8 = 12;
        test_coin::init_coin<DummyCoin>(owner, b"DUMMY", decimals);
        price_oracle::register_oracle_with_fixed_price<DummyCoin>(owner, 1000000000000, decimals, false);
        price_oracle::change_mode<DummyCoin>(owner, 1);
        let expected = 100000 / math64::pow(10, (decimals - coin::decimals<usdz::USDZ>() as u64));
        assert!(borrowable_usdz<DummyCoin>(100000) == expected, 0);
    }
    #[test(owner=@leizd_aptos_trove,aptos_framework=@aptos_framework)]
    fun test_borrowable_usdz__check_overflow__maximum_allowable_value(owner: &signer) {
        account::create_account_for_test(signer::address_of(owner));
        test_coin::init_coin<DummyCoin>(owner, b"DUMMY", 8);
        initialize(owner);
        initialize_oracle(owner);
        price_oracle::register_oracle_with_fixed_price<DummyCoin>(owner, 100000000, 8, false);
        price_oracle::change_mode<DummyCoin>(owner, 1);

        let u64_max: u64 = 18446744073709551615;
        assert!(borrowable_usdz<DummyCoin>(u64_max) == u64_max, 0);
    }
    #[test(owner=@leizd_aptos_trove,aptos_framework=@aptos_framework)]
    #[expected_failure]
    fun test_borrowable_usdz__check_overflow(owner: &signer) {
        account::create_account_for_test(signer::address_of(owner));
        test_coin::init_coin<DummyCoin>(owner, b"DUMMY", 0);
        initialize(owner);
        initialize_oracle(owner);

        let u64_max: u64 = 18446744073709551615;
        borrowable_usdz<DummyCoin>(u64_max);
    }
}
