// TODO: This file and related logic should be moved under `leizd-aptos-stablecoin`
module leizd::trove {
    use aptos_framework::coin;
    use leizd::usdz;
    use aptos_std::event;
    use leizd::permission;
    //use leizd::price_oracle;

    struct Trove<phantom C> has key {
        coin: coin::Coin<C>
    }

    struct SupportedCoin<phantom C> has key {
        coin: coin::Coin<C>
    }

    struct OpenTroveEvent has store, drop {
        caller: address,
        amount: u64,
    }

    struct CloseTroveEvent has store, drop {
        caller: address,
    }

    struct RepayEvent has store, drop {
        caller: address,
        amount: u64,
    }

    struct TroveEventHandle<phantom C> has key, store {
        open_trove_event: event::EventHandle<OpenTroveEvent>,
        close_trove_event: event::EventHandle<CloseTroveEvent>,
        repay_event: event::EventHandle<RepayEvent>,
    }    
    
    public entry fun initialize(owner: &signer) {
        permission::assert_owner(signer::address_of(owner));
        usdz::initialize(owner);
        move_to(owner, SupportedCoin<USDC> {
            coin: coin::zero<USDC>(),
        });
        move_to(owner, SupportedCoin<USDT> {
            coin: coin::zero<USDT>(),
        });
    }

    public entry fun add_supported_coin<C>(owner: &signer) {
        permission::assert_owner(signer::address_of(owner));
        move_to(owner, SupportedCoin<C> {
            coin: coin::zero<C>(),
        });
    }

    public entry fun open_trove<C>(account: &signer, amount: u64) acquires Trove {
        open_trove_internal<C>(account, amount, borrowable_usdz<C>(amount));
    }

    fun  validate_open_trove<C>() {
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
        exists<SupportedCoin<C>>(@leizd)
    }

    public entry fun close_trove<C>(account: &signer) acquires Trove {
        close_trove_internal<C>(account);
    }

    public entry fun repay<C>(account: &signer, collateral_amount: u64) acquires Trove {
        repay_internal<C>(account, collateral_amount);
    }


    public entry fun borrowable_usdz<C>(amount:u64):u64 {
        //let price = price_oracle::price<C>();
        let price = 1;
        let decimals = (coin::decimals<C>() as u64);
        let decimals_usdz = (coin::decimals<usdz::USDZ>() as u64);
        (price * amount) * decimals_usdz / decimals
    }


    fun open_trove_internal<C>(account: &signer, collateral_amount: u64, amount: u64) acquires Trove {
        validate_open_trove<C>();
        let initialized = exists<Trove<C>>(signer::address_of(account));
        if (!initialized) {
            move_to(account, Trove<C> {
                    coin: coin::zero<C>(),
            });
        };
        let trove = borrow_global_mut<Trove<C>>(signer::address_of(account));
        coin::merge(&mut trove.coin, coin::withdraw<C>(account, collateral_amount));        
        usdz::mint(account, amount);
    }

    fun close_trove_internal<C>(account: &signer) acquires Trove {
        validate_close_trove<C>();
        let trove = borrow_global_mut<Trove<C>>(signer::address_of(account));
        let balance = coin::value(&trove.coin);
        repay_internal<C>(account, balance);
    }

    fun repay_internal<C>(account: &signer, collateral_amount: u64) acquires Trove {
        validate_repay<C>();
        let trove = borrow_global_mut<Trove<C>>(signer::address_of(account));
        usdz::burn(account, borrowable_usdz<C>(collateral_amount));
        coin::deposit<C>(signer::address_of(account), coin::extract(&mut trove.coin, collateral_amount));
    }


    #[test_only]
    fun open_trove_for_test<C>(account: &signer, amount: u64) acquires Trove {
        open_trove_internal<C>(account, amount, amount);
    }

    #[test_only]
    use aptos_framework::managed_coin;
    #[test_only]
    use aptos_framework::account;
    #[test_only]
    use leizd::test_coin::{Self,USDC,USDT,WETH};
    #[test_only]
    use aptos_framework::signer;
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
        initialize(owner);
    }

    #[test(owner=@leizd,account1=@0x111,aptos_framework=@aptos_framework)]
    fun test_open_trove(owner: signer, account1: signer) acquires Trove {
        set_up(&owner, &account1);
        let account1_addr = signer::address_of(&account1);
        let usdc_amt = 10000;
        let want = usdc_amt * 3;
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
    fun test_close_trove(owner: signer, account1: signer) acquires Trove {
        set_up(&owner, &account1);
        open_trove<USDC>(&account1, 10000);
        close_trove<USDC>(&account1);
        let account1_addr = signer::address_of(&account1);
        assert!(coin::balance<USDC>(account1_addr) == 10000, 0);
        let trove = borrow_global<Trove<USDC>>(account1_addr);
        assert!(coin::value(&trove.coin) == 0, 0);
    }

    #[test(owner=@leizd,account1=@0x111,aptos_framework=@aptos_framework)]
    fun test_repay(owner: signer, account1: signer) acquires Trove {
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
        let usdc_want = usdc_amt * 3;
        test_coin::init_usdc(&owner);
        initialize(&owner);
        assert!(comparator::is_equal(&comparator::compare(
            &borrowable_usdz<USDC>(usdc_amt),
            &usdc_want
        )), 0);
    }

}