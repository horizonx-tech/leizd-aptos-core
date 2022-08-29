module leizd::stability_pool {

    use std::signer;
    use aptos_framework::coin;
    use aptos_framework::event;
    use aptos_framework::account;
    use leizd::usdz::{USDZ};
    use leizd::stb_usdz;
    use leizd::permission;

    friend leizd::pool;

    const PRECISION: u64 = 1000000000;
    const STABILITY_FEE: u64 = 1000000000 * 5 / 1000; // 0.5%

    const E_IS_ALREADY_EXISTED: u64 = 1;

    struct StabilityPool has key {
        left: coin::Coin<USDZ>,
        total_deposited: u128,
        collected_fee: coin::Coin<USDZ>,
    }

    struct Balance<phantom C> has key {
        total_borrowed: u128,
        uncollected_fee: u64,
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
        permission::assert_owner(signer::address_of(owner));
        assert!(!is_pool_initialized(), E_IS_ALREADY_EXISTED);

        stb_usdz::initialize(owner);
        move_to(owner, StabilityPool {
            left: coin::zero<USDZ>(),
            total_deposited: 0,
            collected_fee: coin::zero<USDZ>(),
        });
        move_to(owner, StabilityPoolEventHandle {
            deposit_event: account::new_event_handle<DepositEvent>(owner),
            withdraw_event: account::new_event_handle<WithdrawEvent>(owner),
            borrow_event: account::new_event_handle<BorrowEvent>(owner),
            repay_event: account::new_event_handle<RepayEvent>(owner),
        })
    }

    public fun is_pool_initialized(): bool {
        exists<StabilityPool>(@leizd)
    }

    public(friend) fun init_pool<C>(owner: &signer) {
        move_to(owner, Balance<C> {
            total_borrowed: 0,
            uncollected_fee: 0
        });
    }

    public entry fun deposit(account: &signer, amount: u64) acquires StabilityPool, StabilityPoolEventHandle {
        let pool_ref = borrow_global_mut<StabilityPool>(@leizd);
        
        coin::merge(&mut pool_ref.left, coin::withdraw<USDZ>(account, amount));
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

        coin::deposit(signer::address_of(account), coin::extract(&mut pool_ref.left, amount));
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

    public fun stability_fee_amount(borrow_amount: u64): u64 {
        borrow_amount * STABILITY_FEE / PRECISION
    }

    fun borrow_internal<C>(amount: u64): coin::Coin<USDZ> acquires StabilityPool, Balance {
        let pool_ref = borrow_global_mut<StabilityPool>(@leizd);
        let balance_ref = borrow_global_mut<Balance<C>>(@leizd);
        assert!(coin::value<USDZ>(&pool_ref.left) >= amount, 0);

        let fee = stability_fee_amount(amount);
        balance_ref.total_borrowed = balance_ref.total_borrowed + (amount as u128) + (fee as u128);
        balance_ref.uncollected_fee = balance_ref.uncollected_fee + fee;
        coin::extract<USDZ>(&mut pool_ref.left, amount)
    }

    public(friend) entry fun repay<C>(account: &signer, amount: u64) acquires StabilityPool, Balance, StabilityPoolEventHandle {
        repay_internal<C>(account, amount);
        event::emit_event<RepayEvent>(
            &mut borrow_global_mut<StabilityPoolEventHandle>(@leizd).repay_event,
            RepayEvent {
                caller: signer::address_of(account),
                repayer: signer::address_of(account),
                amount: amount
            }
        );
    }

    // public entry fun claim_reward(account: &signer, amount: u64) {
    //     // TODO
    // }

    fun repay_internal<C>(account: &signer, amount: u64) acquires StabilityPool, Balance {
        let pool_ref = borrow_global_mut<StabilityPool>(@leizd);
        let balance_ref = borrow_global_mut<Balance<C>>(@leizd);

        if (balance_ref.uncollected_fee > 0) {
            // collect as fees at first
            if (balance_ref.uncollected_fee >= amount) {
                balance_ref.total_borrowed = balance_ref.total_borrowed - (amount as u128);
                balance_ref.uncollected_fee = balance_ref.uncollected_fee - amount;
                coin::merge<USDZ>(&mut pool_ref.collected_fee, coin::withdraw<USDZ>(account, amount));
            } else {
                let to_fee = balance_ref.uncollected_fee;
                let to_left = amount - to_fee;
                balance_ref.total_borrowed = balance_ref.total_borrowed - (amount as u128);
                balance_ref.uncollected_fee = 0;
                coin::merge<USDZ>(&mut pool_ref.collected_fee, coin::withdraw<USDZ>(account, to_fee));
                coin::merge<USDZ>(&mut pool_ref.left, coin::withdraw<USDZ>(account, to_left));
            }
        } else {
            balance_ref.total_borrowed = balance_ref.total_borrowed - (amount as u128);
            coin::merge<USDZ>(&mut pool_ref.left, coin::withdraw<USDZ>(account, amount));
        };
    }

    public fun left(): u128 acquires StabilityPool {
        (coin::value<USDZ>(&borrow_global<StabilityPool>(@leizd).left) as u128)
    }

    public fun collected_fee(): u64 acquires StabilityPool {
        coin::value<USDZ>(&borrow_global<StabilityPool>(@leizd).collected_fee)
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
    use leizd::test_coin::{Self,WETH};
    #[test_only]
    use leizd::usdz;
    #[test_only]
    use leizd::test_initializer;
    #[test_only]
    use leizd::trove;

    #[test(owner=@leizd,account1=@0x111,account2=@0x222,aptos_framework=@aptos_framework)]
    public entry fun test_deposit_to_stability_pool(owner: &signer, account1: &signer) acquires StabilityPool, StabilityPoolEventHandle {
        let owner_addr = signer::address_of(owner);
        let account1_addr = signer::address_of(account1);
        account::create_account_for_test(owner_addr);
        account::create_account_for_test(account1_addr);

        test_coin::init_weth(owner);
        trove::initialize(owner);
        test_initializer::register<WETH>(account1);
        managed_coin::mint<WETH>(owner, account1_addr, 1000000);
        test_initializer::register<USDZ>(account1);
        usdz::mint_for_test(account1_addr, 1000000);

        initialize(owner); // stability pool
        init_pool<WETH>(owner);
                
        deposit(account1, 400000);
        assert!(left() == 400000, 0);
        assert!(total_deposited() == 400000, 0);
        assert!(usdz::balance_of(account1_addr) == 600000, 0);
        assert!(stb_usdz::balance_of(account1_addr) == 400000, 0);
    }

    #[test(owner=@leizd,account1=@0x111,account2=@0x222,aptos_framework=@aptos_framework)]
    public entry fun test_withdraw_from_stability_pool(owner: &signer, account1: &signer) acquires StabilityPool, StabilityPoolEventHandle {
        let owner_addr = signer::address_of(owner);
        let account1_addr = signer::address_of(account1);
        account::create_account_for_test(owner_addr);
        account::create_account_for_test(account1_addr);

        test_coin::init_weth(owner);
        trove::initialize(owner);
        test_initializer::register<WETH>(account1);
        managed_coin::mint<WETH>(owner, account1_addr, 1000000);
        test_initializer::register<USDZ>(account1);
        usdz::mint_for_test(account1_addr, 1000000);

        initialize(owner); // stability pool
        init_pool<WETH>(owner);
                
        deposit(account1, 400000);

        withdraw(account1, 300000);
        assert!(left() == 100000, 0);
        assert!(total_deposited() == 100000, 0);
        assert!(usdz::balance_of(account1_addr) == 900000, 0);
        assert!(stb_usdz::balance_of(account1_addr) == 100000, 0);
    }

    #[test(owner=@leizd,account1=@0x111,account2=@0x222,aptos_framework=@aptos_framework)]
    #[expected_failure]
    public entry fun test_withdraw_without_any_deposit(owner: &signer, account1: &signer, account2: &signer) acquires StabilityPool, StabilityPoolEventHandle {
        let owner_addr = signer::address_of(owner);
        let account1_addr = signer::address_of(account1);
        let account2_addr = signer::address_of(account2);
        account::create_account_for_test(owner_addr);
        account::create_account_for_test(account1_addr);
        account::create_account_for_test(account2_addr);

        test_coin::init_weth(owner);
        trove::initialize(owner);
        test_initializer::register<WETH>(account1);
        managed_coin::mint<WETH>(owner, account1_addr, 1000000);
        test_initializer::register<USDZ>(account1);
        usdz::mint_for_test(account1_addr, 1000000);

        initialize(owner); // stability pool
        init_pool<WETH>(owner);
                
        deposit(account1, 400000);
        withdraw(account2, 300000);
    }

    #[test(owner=@leizd,account1=@0x111,account2=@0x222,aptos_framework=@aptos_framework)]
    public entry fun test_borrow_from_stability_pool(owner: &signer, account1: &signer, account2: &signer) acquires StabilityPool, Balance, StabilityPoolEventHandle {
        let owner_addr = signer::address_of(owner);
        let account1_addr = signer::address_of(account1);
        let account2_addr = signer::address_of(account2);
        account::create_account_for_test(owner_addr);
        account::create_account_for_test(account1_addr);
        account::create_account_for_test(account2_addr);

        test_coin::init_weth(owner);
        trove::initialize(owner);
        test_initializer::register<WETH>(account1);
        managed_coin::mint<WETH>(owner, account1_addr, 1000000);
        test_initializer::register<WETH>(account2);
        test_initializer::register<USDZ>(account1);
        usdz::mint_for_test(account1_addr, 1000000);
        test_initializer::register<USDZ>(account2);

        initialize(owner); // stability pool
        init_pool<WETH>(owner);
                
        deposit(account1, 400000);
        let borrowed = borrow_internal<WETH>(300000);
        coin::deposit(account2_addr, borrowed);
        assert!(left() == 100000, 0);
        assert!(total_deposited() == 400000, 0);
        assert!(total_borrowed<WETH>() == 301500, 0);
        assert!(usdz::balance_of(account2_addr) == 300000, 0);
        assert!(stb_usdz::balance_of(account1_addr) == 400000, 0);
    }

    #[test(owner=@leizd,account1=@0x111,account2=@0x222,aptos_framework=@aptos_framework)]
    public entry fun test_repay_to_stability_pool(owner: &signer, account1: &signer, account2: &signer) acquires StabilityPool, Balance, StabilityPoolEventHandle {
        let owner_addr = signer::address_of(owner);
        let account1_addr = signer::address_of(account1);
        let account2_addr = signer::address_of(account2);
        account::create_account_for_test(owner_addr);
        account::create_account_for_test(account1_addr);
        account::create_account_for_test(account2_addr);

        test_coin::init_weth(owner);
        trove::initialize(owner);
        test_initializer::register<WETH>(account1);
        managed_coin::mint<WETH>(owner, account1_addr, 1000000);
        test_initializer::register<WETH>(account2);
        test_initializer::register<USDZ>(account1);
        usdz::mint_for_test(account1_addr, 1000000);
        test_initializer::register<USDZ>(account2);

        initialize(owner); // stability pool
        init_pool<WETH>(owner);
                
        deposit(account1, 400000);
        let borrowed = borrow_internal<WETH>(300000);
        coin::deposit(account2_addr, borrowed);
        // let repayed = coin::withdraw<USDZ>(&account2, 200000);
        repay_internal<WETH>(account2, 200000);
        assert!(left() == 298500, 0);
        assert!(collected_fee() == 1500, 0);
        assert!(total_deposited() == 400000, 0);
        assert!(total_borrowed<WETH>() == 101500, 0);
        assert!(usdz::balance_of(account2_addr) == 100000, 0);
        assert!(stb_usdz::balance_of(account1_addr) == 400000, 0);
    }
}