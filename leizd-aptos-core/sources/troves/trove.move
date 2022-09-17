// TODO: This file and related logic should be moved under `leizd-aptos-stablecoin`
module leizd::trove {
    use std::signer;
    use aptos_std::event;
    use aptos_framework::coin;
    use leizd::usdz;
    use leizd_aptos_lib::math64;
    use leizd_aptos_common::permission;
    use aptos_framework::account;
    friend leizd::trove_manager;

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

    public(friend) entry fun add_supported_coin<C>(owner: &signer) {
        add_supported_coin_internal<C>(owner);
    }

    fun add_supported_coin_internal<C>(owner: &signer) {
        permission::assert_owner(signer::address_of(owner));
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
    

    public(friend) entry fun open_trove<C>(account: &signer, amount: u64) acquires Trove, TroveEventHandle {
        open_trove_internal<C>(account, amount, borrowable_usdz<C>(amount));
    }

    public(friend) entry fun redeem<C>(account: &signer, target_account: address, amount: u64) acquires Trove{
        redeem_internal<C>(account, target_account, amount)
    }

    fun redeem_internal<C>(account: &signer, target_account:address, amount: u64) acquires Trove {
        let target = borrow_global_mut<Trove<C>>(target_account);
        assert!(coin::value(&target.coin) >= amount, 0);
        usdz::burn(account, borrowable_usdz<C>(amount));
        let deposited = coin::extract(&mut target.coin, amount);
        coin::deposit<C>(signer::address_of(account), deposited);
    }

//    fun requireMaxFeePercentage(_input: RedeemInput){}
    fun requireAfterBootstrapPeriod(){}
    fun rquireTCRoverMCR(_price: u64) {}
    fun requireAmountGreaterThanZero(_amount:u64){}
    fun requireUSDZBalanceCoversRedemption(){}

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
        assert!(is_coin_supported<C>(), 0)
    }

    fun is_coin_supported<C>(): bool {
        exists<SupportedCoin<C>>(permission::owner_address())
    }

    public(friend) entry fun close_trove<C>(account: &signer) acquires Trove, TroveEventHandle {
        close_trove_internal<C>(account);
    }

    public(friend) entry fun repay<C>(account: &signer, collateral_amount: u64) acquires Trove, TroveEventHandle {
        repay_internal<C>(account, collateral_amount);
    }

    public entry fun borrowable_usdz<C>(amount:u64):u64 {
        //let price = price_oracle::price<C>();
        let price = 1;
        let decimals = (coin::decimals<C>() as u64);
        let decimals_usdz = (coin::decimals<usdz::USDZ>() as u64);
        (price * amount) * (math64::pow(10, decimals_usdz) / (math64::pow(10, decimals)))
    }

    fun open_trove_internal<C>(account: &signer, collateral_amount: u64, amount: u64) acquires Trove, TroveEventHandle {
        let account_addr = signer::address_of(account);
        //validate_open_trove<C>(account_addr);
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
    fun open_trove_for_test<C>(account: &signer, amount: u64) acquires Trove, TroveEventHandle {
        open_trove_internal<C>(account, amount, amount);
    }

    #[test_only]
    use aptos_framework::managed_coin;
    #[test_only]
    use leizd::test_coin::{Self,USDC,USDT,WETH};
    #[test_only]
    use aptos_std::comparator;

    #[test_only]
    fun set_up(owner: &signer, account1: &signer) {
        let owner_addr = signer::address_of(owner);
        let account1_addr = signer::address_of(account1);
        let usdc_amt = 10000;
        account::create_account_for_test(owner_addr);
        account::create_account_for_test(account1_addr);
        test_coin::init_usdc(owner);
        test_coin::init_usdt(owner);
        test_coin::init_weth(owner);
        managed_coin::register<USDC>(account1);
        managed_coin::register<USDT>(account1);
        managed_coin::register<WETH>(account1);
        managed_coin::register<usdz::USDZ>(account1);
        managed_coin::mint<USDC>(owner, account1_addr, usdc_amt);
        managed_coin::mint<USDT>(owner, account1_addr, usdc_amt);
        managed_coin::mint<WETH>(owner, account1_addr, usdc_amt);
        initialize_internal(owner);
        add_supported_coin_internal<USDC>(owner);
        add_supported_coin_internal<USDT>(owner);
    }

    #[test(owner=@leizd,account1=@0x111,aptos_framework=@aptos_framework)]
    fun test_open_trove(owner: signer, account1: signer) acquires Trove, TroveEventHandle {
        set_up(&owner, &account1);
        let account1_addr = signer::address_of(&account1);
        let usdc_amt = 10000;
        let want = usdc_amt * math64::pow(10, 12);
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

    #[test(owner=@leizd,account1=@0x111,aptos_framework=@aptos_framework)]
    fun test_close_trove(owner: signer, account1: signer) acquires Trove, TroveEventHandle {
        set_up(&owner, &account1);
        open_trove<USDC>(&account1, 10000);
        close_trove<USDC>(&account1);
        let account1_addr = signer::address_of(&account1);
        assert!(coin::balance<USDC>(account1_addr) == 10000, 0);
        let trove = borrow_global<Trove<USDC>>(account1_addr);
        assert!(coin::value(&trove.coin) == 0, 0);
    }    

    #[test(owner=@leizd,account1=@0x111,aptos_framework=@aptos_framework)]
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

    #[test(owner=@leizd,aptos_framework=@aptos_framework)]
    fun test_usdz_amount(owner: signer)  {
        let owner_addr = signer::address_of(&owner);
        account::create_account_for_test(owner_addr);
        let usdc_amt = 12345678;
        let usdc_want = usdc_amt * math64::pow(10, 12);
        test_coin::init_usdc(&owner);
        initialize(&owner);
        assert!(comparator::is_equal(&comparator::compare(
            &borrowable_usdz<USDC>(usdc_amt),
            &usdc_want
        )), 0);
    }

}