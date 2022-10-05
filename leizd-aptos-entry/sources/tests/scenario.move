#[test_only]
module leizd_aptos_entry::scenario {

    use std::signer;
    use std::vector;
    use std::unit_test;
    use aptos_framework::account;
    // use aptos_framework::coin;
    use aptos_framework::managed_coin;
    use leizd_aptos_common::test_coin::{Self,USDC,USDT,WETH,UNI};
    use leizd_aptos_trove::usdz::{Self, USDZ};
    use leizd_aptos_entry::money_market;

    #[test_only]
    fun initialize_signer_for_test(num_signers: u64): vector<signer> {
        let signers = unit_test::create_signers_for_testing(num_signers);

        let i = vector::length<signer>(&signers);
        while (i > 0) {
            let account = vector::borrow(&signers, i - 1);
            account::create_account_for_test(signer::address_of(account));
            register_all_coins(account);
            i = i - 1;
        };

        signers
    }
    #[test_only]
    fun borrow_account(accounts: &vector<signer>, index: u64): (&signer, address) {
        let account = vector::borrow(accounts, index);
        (account, signer::address_of(account))
    }
    #[test_only]
    fun initialize_scenario(owner: &signer) {
        let owner_addr = signer::address_of(owner);
        account::create_account_for_test(owner_addr);

        test_coin::init_usdc(owner);
        test_coin::init_usdt(owner);
        test_coin::init_weth(owner);
        test_coin::init_uni(owner);

        money_market::initialize(owner);
    }
    #[test_only]
    fun register_all_coins(account: &signer) {
        managed_coin::register<USDC>(account);
        managed_coin::register<USDT>(account);
        managed_coin::register<WETH>(account);
        managed_coin::register<UNI>(account);
        managed_coin::register<USDZ>(account);
    }
    #[test_only]
    fun mint_all(owner: &signer, account_addr: address, amount: u64) {
        managed_coin::mint<WETH>(owner, account_addr, amount);
        managed_coin::mint<USDT>(owner, account_addr, amount);
        managed_coin::mint<WETH>(owner, account_addr, amount);
        managed_coin::mint<UNI>(owner, account_addr, amount);
        usdz::mint_for_test(account_addr, amount);
    }
}