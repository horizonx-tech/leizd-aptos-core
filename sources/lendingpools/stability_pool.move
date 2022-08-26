module leizd::stability_pool {

    use std::signer;
    use aptos_framework::coin;
    use aptos_framework::event;
    use aptos_framework::account;
    use leizd::usdz::{USDZ};
    use leizd::stb_usdz;

    friend leizd::pool;

    struct StabilityPool has key {
        shadow: coin::Coin<USDZ>,
        total_deposited: u128,
    }

    struct Balance<phantom C> has key {
        total_borrowed: u128,
    }

    struct DepositEvent has store, drop {
        caller: address,
        depositor: address,
        amount: u64
    }

    struct WithdrawEvent has store, drop {
        caller: address,
        depositor: address,
        amount: u64
    }

    struct BorrowEvent has store, drop {
        caller: address,
        borrower: address,
        amount: u64
    }

    struct RepayEvent has store, drop {
        caller: address,
        repayer: address,
        amount: u64
    }

    struct StabilityPoolEventHandle has key, store {
        deposit_event: event::EventHandle<DepositEvent>,
        withdraw_event: event::EventHandle<WithdrawEvent>,
        borrow_event: event::EventHandle<BorrowEvent>,
        repay_event: event::EventHandle<RepayEvent>,
    }

    public entry fun initialize(owner: &signer) {
        stb_usdz::initialize(owner);
        move_to(owner, StabilityPool {
            shadow: coin::zero<USDZ>(),
            total_deposited: 0
        });
        move_to(owner, StabilityPoolEventHandle {
            deposit_event: account::new_event_handle<DepositEvent>(owner),
            withdraw_event: account::new_event_handle<WithdrawEvent>(owner),
            borrow_event: account::new_event_handle<BorrowEvent>(owner),
            repay_event: account::new_event_handle<RepayEvent>(owner),
        })
    }

    public entry fun init_pool<C>(owner: &signer) {
        move_to(owner, Balance<C> {
            total_borrowed: 0
        });
    }

    public entry fun deposit(account: &signer, amount: u64) acquires StabilityPool, StabilityPoolEventHandle {
        let pool_ref = borrow_global_mut<StabilityPool>(@leizd);
        
        coin::merge(&mut pool_ref.shadow, coin::withdraw<USDZ>(account, amount));
        pool_ref.total_deposited = pool_ref.total_deposited + (amount as u128);
        if (!stb_usdz::is_account_registered(signer::address_of(account))) {
            stb_usdz::register(account);
        };
        stb_usdz::mint(signer::address_of(account), amount);
        event::emit_event<DepositEvent>(
            &mut borrow_global_mut<StabilityPoolEventHandle>(@leizd).deposit_event,
            DepositEvent {
                caller: signer::address_of(account),
                depositor: signer::address_of(account),
                amount
            }
        );
    }

    public entry fun withdraw(account: &signer, amount: u64) acquires StabilityPool, StabilityPoolEventHandle {
        let pool_ref = borrow_global_mut<StabilityPool>(@leizd);

        coin::deposit(signer::address_of(account), coin::extract(&mut pool_ref.shadow, amount));
        pool_ref.total_deposited = pool_ref.total_deposited - (amount as u128);
        stb_usdz::burn(account, amount);
        event::emit_event<WithdrawEvent>(
            &mut borrow_global_mut<StabilityPoolEventHandle>(@leizd).withdraw_event,
            WithdrawEvent {
                caller: signer::address_of(account),
                depositor: signer::address_of(account),
                amount
            }
        );
    }

    public(friend) entry fun borrow<C>(addr: address, amount: u64): coin::Coin<USDZ> acquires StabilityPool, Balance, StabilityPoolEventHandle {
        let borrowed = borrow_internal<C>(amount);
        event::emit_event<WithdrawEvent>(
            &mut borrow_global_mut<StabilityPoolEventHandle>(@leizd).withdraw_event,
            WithdrawEvent {
                caller: addr,
                depositor: addr,
                amount
            }
        );
        borrowed
    }

    fun borrow_internal<C>(amount: u64): coin::Coin<USDZ> acquires StabilityPool, Balance {
        let pool_ref = borrow_global_mut<StabilityPool>(@leizd);
        let balance_ref = borrow_global_mut<Balance<C>>(@leizd);
        assert!(coin::value<USDZ>(&pool_ref.shadow) >= amount, 0);

        balance_ref.total_borrowed = balance_ref.total_borrowed + (amount as u128);
        coin::extract<USDZ>(&mut pool_ref.shadow, amount)
    }

    public(friend) entry fun repay<C>(addr: address, shadow: coin::Coin<USDZ>) acquires StabilityPool, Balance, StabilityPoolEventHandle {
        let repaid = repay_internal<C>(shadow);
        event::emit_event<RepayEvent>(
            &mut borrow_global_mut<StabilityPoolEventHandle>(@leizd).repay_event,
            RepayEvent {
                caller: addr,
                repayer: addr,
                amount: repaid
            }
        );
    }

    fun repay_internal<C>(shadow: coin::Coin<USDZ>): u64 acquires StabilityPool, Balance {
        let pool_ref = borrow_global_mut<StabilityPool>(@leizd);
        let balance_ref = borrow_global_mut<Balance<C>>(@leizd);

        let amount = (coin::value<USDZ>(&shadow) as u128);
        balance_ref.total_borrowed = balance_ref.total_borrowed - amount;
        coin::merge<USDZ>(&mut pool_ref.shadow, shadow);
        (amount as u64)
    }

    public fun balance(): u128 acquires StabilityPool {
        (coin::value<USDZ>(&borrow_global<StabilityPool>(@leizd).shadow) as u128)
    }

    public fun total_deposited(): u128 acquires StabilityPool {
        borrow_global<StabilityPool>(@leizd).total_deposited
    }

    public fun total_borrowed<C>(): u128 acquires Balance {
        borrow_global<Balance<C>>(@leizd).total_borrowed
    }

    #[test_only]
    use aptos_framework::managed_coin;
    #[test_only]
    use leizd::test_common::{Self,WETH};
    #[test_only]
    use leizd::usdz;
    #[test_only]
    use leizd::initializer;

    #[test(owner=@leizd,account1=@0x111,account2=@0x222,aptos_framework=@aptos_framework)]
    public entry fun test_deposit_to_stability_pool(owner: signer, account1: signer) acquires StabilityPool, StabilityPoolEventHandle {
        let owner_addr = signer::address_of(&owner);
        let account1_addr = signer::address_of(&account1);
        account::create_account_for_test(owner_addr);
        account::create_account_for_test(account1_addr);

        test_common::init_weth(&owner);
        initializer::initialize(&owner);
        initializer::register<WETH>(&account1);
        managed_coin::mint<WETH>(&owner, account1_addr, 1000000);
        initializer::register<USDZ>(&account1);
        usdz::mint_for_test(account1_addr, 1000000);

        initialize(&owner); // stability pool
        init_pool<WETH>(&owner);
                
        deposit(&account1, 400000);
        assert!(balance() == 400000, 0);
        assert!(total_deposited() == 400000, 0);
        assert!(usdz::balance_of(signer::address_of(&account1)) == 600000, 0);
        assert!(stb_usdz::balance_of(signer::address_of(&account1)) == 400000, 0);
    }

    #[test(owner=@leizd,account1=@0x111,account2=@0x222,aptos_framework=@aptos_framework)]
    public entry fun test_withdraw_from_stability_pool(owner: signer, account1: signer) acquires StabilityPool, StabilityPoolEventHandle {
        let owner_addr = signer::address_of(&owner);
        let account1_addr = signer::address_of(&account1);
        account::create_account_for_test(owner_addr);
        account::create_account_for_test(account1_addr);

        test_common::init_weth(&owner);
        initializer::initialize(&owner);
        initializer::register<WETH>(&account1);
        managed_coin::mint<WETH>(&owner, account1_addr, 1000000);
        initializer::register<USDZ>(&account1);
        usdz::mint_for_test(account1_addr, 1000000);

        initialize(&owner); // stability pool
        init_pool<WETH>(&owner);
                
        deposit(&account1, 400000);

        withdraw(&account1, 300000);
        assert!(balance() == 100000, 0);
        assert!(total_deposited() == 100000, 0);
        assert!(usdz::balance_of(signer::address_of(&account1)) == 900000, 0);
        assert!(stb_usdz::balance_of(signer::address_of(&account1)) == 100000, 0);
    }

    #[test(owner=@leizd,account1=@0x111,account2=@0x222,aptos_framework=@aptos_framework)]
    #[expected_failure]
    public entry fun test_withdraw_without_any_deposit(owner: signer, account1: signer, account2: signer) acquires StabilityPool, StabilityPoolEventHandle {
        let owner_addr = signer::address_of(&owner);
        let account1_addr = signer::address_of(&account1);
        let account2_addr = signer::address_of(&account2);
        account::create_account_for_test(owner_addr);
        account::create_account_for_test(account1_addr);
        account::create_account_for_test(account2_addr);

        test_common::init_weth(&owner);
        initializer::initialize(&owner);
        initializer::register<WETH>(&account1);
        managed_coin::mint<WETH>(&owner, account1_addr, 1000000);
        initializer::register<USDZ>(&account1);
        usdz::mint_for_test(account1_addr, 1000000);

        initialize(&owner); // stability pool
        init_pool<WETH>(&owner);
                
        deposit(&account1, 400000);
        withdraw(&account2, 300000);
    }

    #[test(owner=@leizd,account1=@0x111,account2=@0x222,aptos_framework=@aptos_framework)]
    public entry fun test_borrow_from_stability_pool(owner: signer, account1: signer, account2: signer) acquires StabilityPool, Balance, StabilityPoolEventHandle {
        let owner_addr = signer::address_of(&owner);
        let account1_addr = signer::address_of(&account1);
        let account2_addr = signer::address_of(&account2);
        account::create_account_for_test(owner_addr);
        account::create_account_for_test(account1_addr);
        account::create_account_for_test(account2_addr);

        test_common::init_weth(&owner);
        initializer::initialize(&owner);
        initializer::register<WETH>(&account1);
        managed_coin::mint<WETH>(&owner, account1_addr, 1000000);
        initializer::register<WETH>(&account2);
        initializer::register<USDZ>(&account1);
        usdz::mint_for_test(account1_addr, 1000000);
        initializer::register<USDZ>(&account2);

        initialize(&owner); // stability pool
        init_pool<WETH>(&owner);
                
        deposit(&account1, 400000);
        let borrowed = borrow_internal<WETH>(300000);
        coin::deposit(account2_addr, borrowed);
        assert!(balance() == 100000, 0);
        assert!(total_deposited() == 400000, 0);
        assert!(total_borrowed<WETH>() == 300000, 0);
        assert!(usdz::balance_of(signer::address_of(&account2)) == 300000, 0);
        assert!(stb_usdz::balance_of(signer::address_of(&account1)) == 400000, 0);
    }

    #[test(owner=@leizd,account1=@0x111,account2=@0x222,aptos_framework=@aptos_framework)]
    public entry fun test_repay_to_stability_pool(owner: signer, account1: signer, account2: signer) acquires StabilityPool, Balance, StabilityPoolEventHandle {
        let owner_addr = signer::address_of(&owner);
        let account1_addr = signer::address_of(&account1);
        let account2_addr = signer::address_of(&account2);
        account::create_account_for_test(owner_addr);
        account::create_account_for_test(account1_addr);
        account::create_account_for_test(account2_addr);

        test_common::init_weth(&owner);
        initializer::initialize(&owner);
        initializer::register<WETH>(&account1);
        managed_coin::mint<WETH>(&owner, account1_addr, 1000000);
        initializer::register<WETH>(&account2);
        initializer::register<USDZ>(&account1);
        usdz::mint_for_test(account1_addr, 1000000);
        initializer::register<USDZ>(&account2);

        initialize(&owner); // stability pool
        init_pool<WETH>(&owner);
                
        deposit(&account1, 400000);
        let borrowed = borrow_internal<WETH>(300000);
        coin::deposit(account2_addr, borrowed);
        let repayed = coin::withdraw<USDZ>(&account2, 200000);
        repay_internal<WETH>(repayed);
        assert!(balance() == 300000, 0);
        assert!(total_deposited() == 400000, 0);
        assert!(total_borrowed<WETH>() == 100000, 0);
        assert!(usdz::balance_of(signer::address_of(&account2)) == 100000, 0);
        assert!(stb_usdz::balance_of(signer::address_of(&account1)) == 400000, 0);
    }
}