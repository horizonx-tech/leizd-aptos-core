module leizd_aptos_trove::trove_manager {
    use std::signer;
    use leizd_aptos_common::permission;
    use leizd_aptos_trove::trove;

    public fun initialize(owner: &signer) {
        permission::assert_owner(signer::address_of(owner));
        trove::initialize(owner);
    }

    public entry fun initialize_token<C>(owner: &signer) {
        permission::assert_owner(signer::address_of(owner));
        trove::add_supported_coin<C>(owner);
    }

    public entry fun open_trove<C>(account: &signer, amount: u64) {
        trove::open_trove<C>(account, amount);
    }

    public entry fun redeem<C>(account: &signer, target:address, amount: u64) {
        // TODO: redeem
        //let redeemed = 0;
        //while ((redeemed < amount) && target != @0x0) {
        //    let trove_amount = trove::trove_amount<C>(target);
        //    if (amount < redeemed + trove_amount) {
        //        return
        //    }; 
        //    redeem_and_remove_trove<C>(account, next_target_address, trove_amount);
        //    redeemed = redeemed + trove_amount;
        //    next_target_address = sorted_trove::tail<C>();
        //}
    }

    fun redeem_trove<C>(account: &signer, target_address: address, amount: u64) {
        trove::redeem<C>(account, target_address, amount)
    }


    public entry fun close_trove<C>(account: &signer) {
        trove::close_trove<C>(account);
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
    use leizd_aptos_external::price_oracle;
    #[test_only]
    fun alice(owner: &signer): signer { create_user(owner, @0x1) }
    #[test_only]
    fun bob(owner: &signer): signer { create_user(owner, @0x2) }
    #[test_only]
    fun carol(owner: &signer): signer { create_user(owner, @0x3) }
    #[test_only]
    fun users(owner: &signer):(signer, signer, signer) { (alice(owner), bob(owner), carol(owner)) }
    #[test_only]
    const INITIAL_BALANCE: u64 = 100000000000000000;    

    #[test_only]
    fun set_up(owner: &signer) {
        let owner_addr = signer::address_of(owner);
        account::create_account_for_test(owner_addr);
        initialize(owner);
        test_coin::init_usdc(owner);
        initialize_token<USDC>(owner);
        price_oracle::initialize(owner);
        price_oracle::register_oracle_with_fixed_price<USDC>(owner, 1000000, 6, false);
        price_oracle::change_mode<USDC>(owner, 1);
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
   fun test_redeem(owner: &signer) {
        set_up(owner);
        let (alice, bob, carol) = users(owner);
        open_trove<USDC>(&alice, 100);
        open_trove<USDC>(&bob, 1000);
        open_trove<USDC>(&carol, 10000);
        coin::transfer<usdz::USDZ>(&carol, signer::address_of(&alice), 5000 * math64::pow(10, 8 - 6));
        let alice_claims_usdc = 5000 + 100;
        let alice_usdz_balance_before = alice_claims_usdc * math64::pow(10, 8 - 6);
        assert!(coin::balance<usdz::USDZ>(signer::address_of(&alice)) == alice_usdz_balance_before, 0);
        assert!(coin::balance<usdz::USDZ>(signer::address_of(&alice)) == 0, 0);
        // alice and bob positions are redeemed
        let carol_trove_remains = 10000 - (5100 - (100 + 1000));
        assert!(trove::trove_amount<USDC>(signer::address_of(&carol)) == carol_trove_remains, 0);
   }
}
