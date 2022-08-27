#[test_only]
module leizd::integration {

    // TODO: integration test
    
    // use std::signer;
    // use aptos_framework::account;
    // // use aptos_framework::coin;
    // // use aptos_framework::managed_coin;
    // use leizd::pool;
    // use leizd::pool_type::{Asset,Shadow};
    // use leizd::test_common::{Self,USDC,WETH};

    // #[test(owner=@leizd)]
    // public entry fun test_init_by_owner(owner: signer) {
    //     // init account
    //     account::create_account_for_test(signer::address_of(&owner));

    //     // init coins
    //     test_common::init_usdc(&owner);
    //     test_common::init_weth(&owner);

    //     // list coins on the pool
    //     pool::init_pool<USDC>(&owner);
    //     pool::init_pool<WETH>(&owner);

    //     assert!(pool::total_deposits<USDC,Asset>() == 0, 0);
    //     assert!(pool::total_deposits<USDC,Shadow>() == 0, 0);
    // }
}