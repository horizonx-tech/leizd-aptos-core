#[test_only]
module leizd_aptos_external::integration {
    use std::signer;
    use aptos_framework::account;
    use switchboard::aggregator;
    use leizd_aptos_lib::math128;
    use leizd_aptos_common::test_coin::{WETH};
    use leizd_aptos_external::price_oracle;
    use leizd_aptos_external::switchboard_adaptor;

    fun initialize_all(owner: &signer) {
        price_oracle::initialize(owner);
        switchboard_adaptor::initialize(owner);
    }
    #[test(owner = @leizd_aptos_external, weth_aggr = @0x111AAA)]
    fun test_use_switchboard_from_price_oracle_mod(owner: &signer, weth_aggr: &signer) {
        account::create_account_for_test(signer::address_of(owner));
        initialize_all(owner);
        price_oracle::add_oracle_without_fixed_price<WETH>(owner);
        price_oracle::change_mode<WETH>(owner, 2);
        aggregator::new_test(weth_aggr, 12345, 0, false);
        switchboard_adaptor::add_aggregator<WETH>(owner, signer::address_of(weth_aggr));

        let (val, dec) = price_oracle::price<WETH>();
        assert!(val == 12345000000000, 0);
        assert!(dec == 9, 0);
        assert!(val / math128::pow(10, (dec as u128)) == 12345, 0);
    }
}
