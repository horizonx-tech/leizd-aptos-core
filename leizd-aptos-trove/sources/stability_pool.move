/*
    The Stability Pool holds USDZ tokens deposited by Stability Pool depositors.
    When a trove is liquidated, then depending on system conditions, some of its LUSD debt gets offset with
    USDZ in the Stablity Pool: that is, the offset debt evaporates, and an equal amount of LUSD tokens in the Stability Pool is burned.
    Thus, a liquidation causes each depositor to receive a USDZ loss, in proportion to their deposit as a share of total deposits.
    They also receive an gain with the collateral assets, as the collateral of the liquidated trove is distributed among Stability depositors,
    in the same proportion.
    When a liquidation occurs, it depletes every deposit by the same fraction: for example, a liquidation that depletes 40%
    of the total USDZ in the Stability Pool, depletes 40% of each deposit.

*/
module leizd_aptos_trove::stability_pool {
    use std::signer;
    use leizd_aptos_common::permission;
    use aptos_framework::coin;
    use leizd_aptos_trove::usdz::{USDZ};

    const EINSUFFICIENT_DEPOSIT: u64 = 1;


    struct StabilityPool has key {
        coin: coin::Coin<USDZ>,
    }

    struct Deposit has key {
        amount: u64
    }


    public fun initialize(owner: &signer) {
        permission::assert_owner(signer::address_of(owner));
        move_to(owner, StabilityPool {
            coin: coin::zero<USDZ>(),
        });
    }

    public fun total_deposit(): u64 acquires StabilityPool {
        coin::value(&borrow_global<StabilityPool>(permission::owner_address()).coin)
    }

    public fun deposit(account: &signer, amount: u64) acquires StabilityPool, Deposit {
        let stability_pool = borrow_global_mut<StabilityPool>(permission::owner_address());
        coin::merge<USDZ>(&mut stability_pool.coin, coin::withdraw<USDZ>(account, amount));
        let account_addr = signer::address_of(account);
        if(!exists<Deposit>(account_addr)) {
            move_to(account, Deposit {
                amount: 0
            });
        };
        let deposit = borrow_global_mut<Deposit>(account_addr);
        deposit.amount = deposit.amount + amount;
    }

    public fun withdraw(account: &signer, amount: u64) acquires StabilityPool, Deposit {
        let stability_pool = borrow_global_mut<StabilityPool>(permission::owner_address());
        let account_addr = signer::address_of(account);
        coin::deposit(account_addr, coin::extract<USDZ>(&mut stability_pool.coin, amount));
        let deposit = borrow_global_mut<Deposit>(account_addr);
        assert!(deposit.amount >= amount, EINSUFFICIENT_DEPOSIT);
        deposit.amount = deposit.amount - amount;
    }

    #[test_only]
    use aptos_framework::account;
    #[test_only]
    use leizd_aptos_trove::usdz::{Self};
    #[test_only]
    use aptos_framework::managed_coin;
    #[test_only]
    const USDZ_AMT: u64 = 100 * 100000000;


    #[test_only]
    fun set_up(owner: &signer) {
        let owner_addr = signer::address_of(owner);
        account::create_account_for_test(owner_addr);
        usdz::initialize_for_test(owner);
        initialize(owner);
    }

    #[test_only]
    fun set_up_account(account: &signer) {
        let addr = signer::address_of(account);
        account::create_account_for_test(addr);
        managed_coin::register<USDZ>(account);
        usdz::mint_for_test(addr, USDZ_AMT);
    }

    #[test(owner=@leizd_aptos_trove,alice=@0x111,aptos_framework=@aptos_framework)]
    fun test_deposit(owner: &signer, alice: &signer) acquires Deposit, StabilityPool {
        set_up(owner);
        set_up_account(alice);
        deposit(alice, USDZ_AMT);
        assert!(borrow_global<Deposit>(signer::address_of(alice)).amount == USDZ_AMT, borrow_global<Deposit>(signer::address_of(alice)).amount);
        assert!(coin::balance<USDZ>(signer::address_of(alice)) == 0, coin::balance<USDZ>(signer::address_of(alice)));
        assert!(coin::value<USDZ>(&borrow_global<StabilityPool>(signer::address_of(owner)).coin) == USDZ_AMT, coin::value<USDZ>(&borrow_global<StabilityPool>(signer::address_of(owner)).coin));
    }

    #[test(owner=@leizd_aptos_trove,alice=@0x111,aptos_framework=@aptos_framework)]
    fun test_withdraw(owner: &signer, alice: &signer) acquires Deposit, StabilityPool {
        set_up(owner);
        set_up_account(alice);
        deposit(alice, USDZ_AMT);
        let want = USDZ_AMT / 2;
        withdraw(alice, want);
        assert!(borrow_global<Deposit>(signer::address_of(alice)).amount == want, borrow_global<Deposit>(signer::address_of(alice)).amount);
        assert!(coin::balance<USDZ>(signer::address_of(alice)) == want, coin::balance<USDZ>(signer::address_of(alice)));
        assert!(coin::value<USDZ>(&borrow_global<StabilityPool>(signer::address_of(owner)).coin) == want, coin::value<USDZ>(&borrow_global<StabilityPool>(signer::address_of(owner)).coin));
    }

    #[test(owner=@leizd_aptos_trove,alice=@0x111,bob=@0x222,aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = 1)]
    fun test_withdraw_over_my_deposit(owner: &signer, alice: &signer, bob: &signer) acquires Deposit, StabilityPool {
        set_up(owner);
        set_up_account(alice);
        set_up_account(bob);
        deposit(alice, USDZ_AMT);
        deposit(bob, USDZ_AMT);
        withdraw(alice, USDZ_AMT + 1);
    }


}
