module leizd_aptos_trove::trove_manager {
    use std::signer;
    use leizd_aptos_common::permission;
    use leizd_aptos_trove::sorted_trove;
    use leizd_aptos_trove::trove;

    public fun initialize(owner: &signer) {
        permission::assert_owner(signer::address_of(owner));
        trove::initialize(owner);
    }

    public entry fun initialize_token<C>(owner: &signer) {
        permission::assert_owner(signer::address_of(owner));
        trove::add_supported_coin<C>(owner);
        sorted_trove::initialize<C>(owner);
    }

    public entry fun open_trove<C>(account: &signer, amount: u64)  {
        trove::open_trove<C>(account, amount);
        sorted_trove::insert<C>(signer::address_of(account))
    }

    public entry fun redeem<C>(account: &signer, amount: u64) {
        let redeemed = 0;
        let next_target_address = sorted_trove::tail<C>();
        while ((redeemed < amount) && next_target_address != @0x0) {
            let trove_amount = trove::trove_amount<C>(next_target_address);
            if (amount < redeemed + trove_amount) {
                redeem_trove<C>(account, next_target_address, amount - redeemed);
                return
            }; 
            redeem_and_remove_trove<C>(account, next_target_address, trove_amount);
            redeemed = redeemed + trove_amount;
            next_target_address = sorted_trove::tail<C>();
        }
    }

    fun redeem_and_remove_trove<C>(account: &signer, target_address: address, amount: u64) {
        redeem_trove<C>(account, target_address, amount);
        remove_trove<C>(target_address)
    }

    fun redeem_trove<C>(account: &signer, target_address: address, amount: u64) {
        trove::redeem<C>(account, target_address, amount)
    }

    fun remove_trove<C>(account: address) {
        sorted_trove::remove<C>(account)
    }

    public entry fun close_trove<C>(account: &signer) {
        trove::close_trove<C>(account);
        remove_trove<C>(signer::address_of(account))
    }

    public entry fun repay<C>(account: &signer, collateral_amount: u64) {
        trove::repay<C>(account, collateral_amount);
    }

    #[test_only]
    use aptos_framework::account;
    #[test_only]
    use aptos_framework::coin;
    #[test_only]
    use aptos_framework::managed_coin;
    #[test_only]
    use leizd_aptos_lib::math64;
    #[test_only]
    use leizd_aptos_trove::usdz;
    #[test_only]
    use leizd_aptos_common::test_coin::{Self,USDC};
    #[test_only]
    fun trove_size(): u64 { sorted_trove::size<USDC>() }
    #[test_only]
    fun trove_head(): address { sorted_trove::head<USDC>() }
    #[test_only]
    fun trove_tail(): address { sorted_trove::tail<USDC>() }
    #[test_only]
    fun node_next(sig: &signer): address { sorted_trove::node_next<USDC>(signer::address_of(sig)) }
    #[test_only]
    fun node_prev(sig: &signer): address { sorted_trove::node_prev<USDC>(signer::address_of(sig)) }
    #[test_only]
    fun alice(owner: &signer): signer { create_user(owner, @0x1) }
    #[test_only]
    fun bob(owner: &signer): signer { create_user(owner, @0x2) }
    #[test_only]
    fun carol(owner: &signer): signer { create_user(owner, @0x3) }
    #[test_only]
    fun users(owner: &signer):(signer, signer, signer) { (alice(owner), bob(owner), carol(owner)) }
    #[test_only]
    const INITIAL_BALANCE:u64 = 100000000000000000;

    #[test_only]
    fun set_up(owner: &signer) {
        let owner_addr = signer::address_of(owner);
        account::create_account_for_test(owner_addr);
        initialize(owner);
        test_coin::init_usdc(owner);
        initialize_token<USDC>(owner);
    }

    #[test_only]
    fun create_user(owner: &signer, account: address): signer {
        let sig = account::create_account_for_test(account);
        managed_coin::register<USDC>(&sig);
        managed_coin::register<usdz::USDZ>(&sig);
        managed_coin::mint<USDC>(owner, account, INITIAL_BALANCE);
        sig
    }

    #[test(owner=@leizd_aptos_trove)]
    fun test_insert(owner: &signer) {
        set_up(owner);
        let (alice, bob, carol) = users(owner);
        open_trove<USDC>(&alice,100);
        assert!(trove_size() == 1, 0);
        assert!(trove_head() == signer::address_of(&alice), 0);
        assert!(trove_tail() == signer::address_of(&alice), 0);
        assert!(node_next(&alice) == @0x0, 0);
        assert!(node_prev(&alice) == @0x0, 0);

        // insert more elem after account1
        open_trove<USDC>(&bob, 1000);
        assert!(trove_size() == 2, 0);
        assert!(trove_head() == signer::address_of(&bob), 0);
        assert!(trove_tail() == signer::address_of(&alice), 0);
        assert!(node_next(&bob) == signer::address_of(&alice), 0);
        assert!(node_prev(&bob) == @0x0, 0);

        // insert more elem between account1 and account2
        open_trove<USDC>(&carol, 500);
        assert!(trove_size() == 3, 0);
        assert!(trove_head() == signer::address_of(&bob), 0);
        assert!(trove_tail() == signer::address_of(&alice), 0);
        assert!(node_next(&carol) == signer::address_of(&alice), 0);
        assert!(node_prev(&alice) == signer::address_of(&carol), 0);
    }

   #[test(owner=@leizd_aptos_trove)]
   fun test_remove_1_entry(owner: &signer) {
        set_up(owner);
        let alice = alice(owner);
        open_trove<USDC>(&alice,1000);
        // remove 1 of 1 element
        close_trove<USDC>(&alice);
        assert!(trove_size() == 0, 0);
        assert!(trove_head() == @0x0, 0);
        assert!(trove_tail() == @0x0, 0);
   }

   #[test(owner=@leizd_aptos_trove)]
   fun test_remove_head_of_2_entries(owner: &signer) {
        set_up(owner);
        let (alice, bob, _) = users(owner);
        open_trove<USDC>(&alice,100);
        open_trove<USDC>(&bob,1000);
        // remove 1 of 2 elements
        close_trove<USDC>(&alice);
        assert!(trove_size() == 1, 0);
        assert!(trove_head() == signer::address_of(&bob), 0);
        assert!(trove_tail() == signer::address_of(&bob), 0);
        assert!(node_next(&bob) == @0x0, 0);
        assert!(node_prev(&bob) == @0x0, 0);
   }

   #[test(owner=@leizd_aptos_trove)]
   fun test_remove_tail_of_2_entries(owner: &signer)  {
        set_up(owner);
        let (alice, bob, _) = users(owner);
        open_trove<USDC>(&alice, 100);
        open_trove<USDC>(&bob, 1000);
        // remove 1 of 2 elements
        close_trove<USDC>(&bob);
        assert!(trove_size() == 1, 0);
        assert!(trove_head() == signer::address_of(&alice), 0);
        assert!(trove_tail() == signer::address_of(&alice), 0);
        assert!(node_next(&alice) == @0x0, 0);
        assert!(node_prev(&alice) == @0x0, 0);
   }
   
   #[test(owner=@leizd_aptos_trove)]
   fun test_remove_head_of_3_entries(owner: &signer) {
        set_up(owner);
        let (alice, bob, carol) = users(owner);
        open_trove<USDC>(&alice, 100);
        open_trove<USDC>(&bob, 1000);
        open_trove<USDC>(&carol, 10000);

        // remove 1 of 3 elements
        close_trove<USDC>(&alice);
        assert!(trove_size() == 2, 0);
        assert!(trove_head() == signer::address_of(&carol), 0);
        assert!(trove_tail() == signer::address_of(&bob), 0);
        assert!(node_next(&bob) == @0x0, 0);
        assert!(node_prev(&bob) == signer::address_of(&carol), 0);
        assert!(sorted_trove::node_next<USDC>(signer::address_of(&bob)) == @0x0, 0);
        assert!(sorted_trove::node_prev<USDC>(signer::address_of(&bob)) == signer::address_of(&carol), 0);
   }

   #[test(owner=@leizd_aptos_trove)]
   fun test_remove_middle_of_3_entries(owner: &signer) {
        set_up(owner);
        let (alice, bob, carol) = users(owner);
        open_trove<USDC>(&alice, 100);
        open_trove<USDC>(&bob, 1000);
        open_trove<USDC>(&carol, 10000);
        // remove 1 of 3 elements
        close_trove<USDC>(&bob);
        assert!(trove_size() == 2, 0);
        assert!(trove_head() == signer::address_of(&carol), 0);
        assert!(trove_tail() == signer::address_of(&alice), 0);
        assert!(node_next(&alice) == @0x0, 0);
        assert!(node_prev(&alice) == signer::address_of(&carol), 0);
        assert!(sorted_trove::node_next<USDC>(signer::address_of(&alice)) == @0x0, 0);
        assert!(sorted_trove::node_prev<USDC>(signer::address_of(&alice)) == signer::address_of(&carol), 0);
   }

   #[test(owner=@leizd_aptos_trove)]
    fun test_remove_tail_of_3_entries(owner: &signer) {
        set_up(owner);
        let (alice, bob, carol) = users(owner);
        open_trove<USDC>(&alice, 100);
        open_trove<USDC>(&bob, 1000);
        open_trove<USDC>(&carol, 10000);
        // remove 1 of 3 elements
        close_trove<USDC>(&carol);
        assert!(trove_size() == 2, 0);
        assert!(trove_head() == signer::address_of(&bob), 0);
        assert!(trove_tail() == signer::address_of(&alice), 0);
        assert!(node_next(&bob) == signer::address_of(&alice), 0);
        assert!(node_prev(&bob) == @0x0, 0);
        assert!(node_next(&alice) == @0x0, 0);
        assert!(node_prev(&alice) == signer::address_of(&bob), 0);
   }

   #[test(owner=@leizd_aptos_trove)]
   fun test_redeem(owner: &signer) {
        set_up(owner);
        let (alice, bob, carol) = users(owner);
        open_trove<USDC>(&alice, 100);
        open_trove<USDC>(&bob, 1000);
        open_trove<USDC>(&carol, 10000);
        coin::transfer<usdz::USDZ>(&carol, signer::address_of(&alice), 5000 * math64::pow(10, 12));
        let alice_claims_usdc = 5000 + 100;
        let alice_usdz_balance_before = alice_claims_usdc * math64::pow(10, 12);
        assert!(coin::balance<usdz::USDZ>(signer::address_of(&alice)) == alice_usdz_balance_before, 0);
        redeem<USDC>(&alice, alice_claims_usdc);
        assert!(coin::balance<usdz::USDZ>(signer::address_of(&alice)) == 0, 0);
        // alice and bob positions are redeemed
        assert!(trove_size() == 1, 0);
        let carol_trove_remains = 10000 - (5100 - (100 + 1000));
        assert!(trove::trove_amount<USDC>(signer::address_of(&carol)) == carol_trove_remains, 0);
        assert!(trove_head() == signer::address_of(&carol), 0);
        assert!(trove_tail() == signer::address_of(&carol), 0);
        assert!(node_next(&carol) == @0x0, 0);
        assert!(node_prev(&carol) == @0x0, 0);
   }
}
