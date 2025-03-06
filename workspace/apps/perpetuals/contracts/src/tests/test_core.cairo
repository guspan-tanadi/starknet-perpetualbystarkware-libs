use contracts_commons::components::deposit::interface::{DepositStatus, IDeposit};
use contracts_commons::components::nonce::interface::INonce;
use contracts_commons::components::replaceability::interface::IReplaceable;
use contracts_commons::components::request_approvals::interface::{IRequestApprovals, RequestStatus};
use contracts_commons::components::roles::interface::IRoles;
use contracts_commons::constants::{HOUR, MAX_U128, TEN_POW_15, TWO_POW_32};
use contracts_commons::iterable_map::*;
use contracts_commons::message_hash::OffchainMessageHash;
use contracts_commons::test_utils::{
    Deployable, TokenTrait, assert_panic_with_error, assert_panic_with_felt_error,
    cheat_caller_address_once,
};
use contracts_commons::types::time::time::{Time, Timestamp};
use core::num::traits::Zero;
use perpetuals::core::components::assets::AssetsComponent::InternalTrait as AssetsInternal;
use perpetuals::core::components::assets::errors::ASSET_ALREADY_EXISTS;
use perpetuals::core::components::assets::interface::{
    IAssets, IAssetsSafeDispatcher, IAssetsSafeDispatcherTrait,
};
use perpetuals::core::components::positions::Positions::POSITION_VERSION;
use perpetuals::core::components::positions::errors::POSITION_DOESNT_EXIST;
use perpetuals::core::components::positions::interface::{
    IPositions, IPositionsSafeDispatcher, IPositionsSafeDispatcherTrait,
};
use perpetuals::core::components::positions::{
    Positions, Positions::InternalTrait as PositionsInternal,
};
use perpetuals::core::core::Core::SNIP12MetadataImpl;
use perpetuals::core::interface::{ICore, ICoreSafeDispatcher, ICoreSafeDispatcherTrait};
use perpetuals::core::types::asset::{AssetIdTrait, AssetStatus};
use perpetuals::core::types::funding::{FundingIndex, FundingTick};
use perpetuals::core::types::order::Order;
use perpetuals::core::types::price::{PriceTrait, SignedPrice};
use perpetuals::core::types::set_owner_account::SetOwnerAccountArgs;
use perpetuals::core::types::set_public_key::SetPublicKeyArgs;
use perpetuals::core::types::transfer::TransferArgs;
use perpetuals::core::types::withdraw::WithdrawArgs;
use perpetuals::tests::constants::*;
use perpetuals::tests::event_test_utils::{
    assert_add_oracle_event_with_expected, assert_add_synthetic_event_with_expected,
    assert_asset_activated_event_with_expected,
    assert_deactivate_synthetic_asset_event_with_expected, assert_deleverage_event_with_expected,
    assert_deposit_canceled_event_with_expected, assert_deposit_event_with_expected,
    assert_deposit_processed_event_with_expected, assert_funding_tick_event_with_expected,
    assert_liquidate_event_with_expected, assert_new_position_event_with_expected,
    assert_price_tick_event_with_expected, assert_register_collateral_event_with_expected,
    assert_remove_oracle_event_with_expected, assert_set_owner_account_event_with_expected,
    assert_set_public_key_event_with_expected, assert_set_public_key_request_event_with_expected,
    assert_trade_event_with_expected, assert_transfer_event_with_expected,
    assert_transfer_request_event_with_expected, assert_withdraw_event_with_expected,
    assert_withdraw_request_event_with_expected,
};
use perpetuals::tests::test_utils::{
    Oracle, OracleTrait, PerpetualsInitConfig, User, UserTrait, add_synthetic_to_position,
    check_synthetic_asset, deposit_hash, init_by_dispatcher, init_position,
    init_position_with_owner, initialized_contract_state, set_roles, setup_state_with_active_asset,
    setup_state_with_pending_asset, validate_balance,
};
use snforge_std::cheatcodes::events::{EventSpyTrait, EventsFilterTrait};
use snforge_std::{start_cheat_block_timestamp_global, test_address};
use starknet::storage::{
    StorageMapReadAccess, StorageMapWriteAccess, StoragePathEntry, StoragePointerReadAccess,
    StoragePointerWriteAccess,
};


#[test]
fn test_constructor() {
    let mut state = initialized_contract_state();
    assert!(state.roles.is_governance_admin(GOVERNANCE_ADMIN()));
    assert_eq!(state.replaceability.get_upgrade_delay(), UPGRADE_DELAY);
    assert_eq!(state.assets.get_price_validation_interval(), MAX_PRICE_INTERVAL);
    assert_eq!(state.assets.get_funding_validation_interval(), MAX_FUNDING_INTERVAL);
    assert_eq!(state.assets.get_max_funding_rate(), MAX_FUNDING_RATE);
    assert_eq!(state.assets.get_max_oracle_price_validity(), MAX_ORACLE_PRICE_VALIDITY);
    assert_eq!(state.deposits.get_deposit_grace_period(), DEPOSIT_GRACE_PERIOD);
    assert_eq!(state.assets.last_funding_tick.read(), Time::now());
    assert_eq!(state.assets.last_price_validation.read(), Time::now());

    assert_eq!(
        state
            .positions
            .get_position_snapshot(position_id: Positions::FEE_POSITION)
            .owner_public_key
            .read(),
        OPERATOR_PUBLIC_KEY(),
    );
    assert_eq!(
        state
            .positions
            .get_position_snapshot(position_id: Positions::INSURANCE_FUND_POSITION)
            .owner_public_key
            .read(),
        OPERATOR_PUBLIC_KEY(),
    );
}


// Invalid cases tests.

#[test]
fn test_caller_failures() {
    // Setup:
    let (cfg, state, _) = init_by_dispatcher();

    let dispatcher = ICoreSafeDispatcher { contract_address: state.address };

    let result = dispatcher
        .process_deposit(
            operator_nonce: Zero::zero(),
            depositor: test_address(),
            position_id: POSITION_ID_1,
            collateral_id: cfg.collateral_cfg.collateral_id,
            amount: DEPOSIT_AMOUNT,
            salt: 0,
        );
    assert_panic_with_error(:result, expected_error: "ONLY_OPERATOR");

    let result = dispatcher
        .withdraw_request(
            signature: array![].span(),
            recipient: test_address(),
            position_id: POSITION_ID_1,
            collateral_id: cfg.collateral_cfg.collateral_id,
            amount: WITHDRAW_AMOUNT.into(),
            expiration: Time::now(),
            salt: 0,
        );
    // Means that any one can call this ABI.
    assert_panic_with_felt_error(:result, expected_error: POSITION_DOESNT_EXIST);

    let result = dispatcher
        .withdraw(
            operator_nonce: Zero::zero(),
            recipient: test_address(),
            position_id: POSITION_ID_1,
            collateral_id: cfg.collateral_cfg.collateral_id,
            amount: WITHDRAW_AMOUNT.into(),
            expiration: Time::now(),
            salt: 0,
        );
    assert_panic_with_error(:result, expected_error: "ONLY_OPERATOR");

    let result = dispatcher
        .transfer_request(
            signature: array![].span(),
            recipient: POSITION_ID_1,
            position_id: POSITION_ID_2,
            collateral_id: cfg.collateral_cfg.collateral_id,
            amount: TRANSFER_AMOUNT.into(),
            expiration: Time::now(),
            salt: 0,
        );
    // Means that any one can call this ABI.
    assert_panic_with_felt_error(:result, expected_error: POSITION_DOESNT_EXIST);

    let result = dispatcher
        .transfer(
            operator_nonce: Zero::zero(),
            recipient: POSITION_ID_1,
            position_id: POSITION_ID_2,
            collateral_id: cfg.collateral_cfg.collateral_id,
            amount: TRANSFER_AMOUNT.into(),
            expiration: Time::now(),
            salt: 0,
        );
    assert_panic_with_error(:result, expected_error: "ONLY_OPERATOR");

    let default_order = Order {
        position_id: POSITION_ID_1,
        base_asset_id: cfg.collateral_cfg.collateral_id,
        base_amount: 0,
        quote_asset_id: cfg.collateral_cfg.collateral_id,
        quote_amount: 0,
        fee_asset_id: cfg.collateral_cfg.collateral_id,
        fee_amount: 0,
        expiration: Time::now(),
        salt: 0,
    };

    let result = dispatcher
        .trade(
            operator_nonce: Zero::zero(),
            signature_a: array![].span(),
            signature_b: array![].span(),
            order_a: default_order,
            order_b: default_order,
            actual_amount_base_a: 0,
            actual_amount_quote_a: 0,
            actual_fee_a: 0,
            actual_fee_b: 0,
        );
    assert_panic_with_error(:result, expected_error: "ONLY_OPERATOR");

    let result = dispatcher
        .liquidate(
            operator_nonce: Zero::zero(),
            liquidator_signature: array![].span(),
            liquidated_position_id: POSITION_ID_1,
            liquidator_order: default_order,
            actual_amount_base_liquidated: 0,
            actual_amount_quote_liquidated: 0,
            actual_liquidator_fee: 0,
            fee_asset_id: cfg.collateral_cfg.collateral_id,
            fee_amount: 0,
        );
    assert_panic_with_error(:result, expected_error: "ONLY_OPERATOR");

    let result = dispatcher
        .deleverage(
            operator_nonce: Zero::zero(),
            deleveraged_position_id: POSITION_ID_1,
            deleverager_position_id: POSITION_ID_1,
            deleveraged_base_asset_id: cfg.collateral_cfg.collateral_id,
            deleveraged_base_amount: 0,
            deleveraged_quote_asset_id: cfg.collateral_cfg.collateral_id,
            deleveraged_quote_amount: 0,
        );
    assert_panic_with_error(:result, expected_error: "ONLY_OPERATOR");

    let dispatcher = IAssetsSafeDispatcher { contract_address: state.address };

    let result = dispatcher
        .register_collateral(
            asset_id: cfg.collateral_cfg.collateral_id,
            token_address: Zero::zero(),
            quantum: Zero::zero(),
        );
    assert_panic_with_error(:result, expected_error: "ONLY_APP_GOVERNOR");

    let result = dispatcher
        .add_oracle_to_asset(
            asset_id: cfg.synthetic_cfg.synthetic_id,
            oracle_public_key: Zero::zero(),
            oracle_name: Zero::zero(),
            asset_name: Zero::zero(),
        );
    assert_panic_with_error(:result, expected_error: "ONLY_APP_GOVERNOR");

    let result = dispatcher
        .add_synthetic_asset(
            asset_id: cfg.synthetic_cfg.synthetic_id,
            risk_factor_tiers: array![].span(),
            risk_factor_first_tier_boundary: Zero::zero(),
            risk_factor_tier_size: Zero::zero(),
            quorum: 0,
            resolution: 0,
        );
    assert_panic_with_error(:result, expected_error: "ONLY_APP_GOVERNOR");

    let result = dispatcher.deactivate_synthetic(synthetic_id: cfg.synthetic_cfg.synthetic_id);
    assert_panic_with_error(:result, expected_error: "ONLY_APP_GOVERNOR");

    let result = dispatcher
        .funding_tick(operator_nonce: Zero::zero(), funding_ticks: array![].span());
    assert_panic_with_error(:result, expected_error: "ONLY_OPERATOR");

    let result = dispatcher
        .price_tick(
            operator_nonce: Zero::zero(),
            asset_id: cfg.synthetic_cfg.synthetic_id,
            oracle_price: Zero::zero(),
            signed_prices: array![].span(),
        );
    assert_panic_with_error(:result, expected_error: "ONLY_OPERATOR");

    let dispatcher = IPositionsSafeDispatcher { contract_address: state.address };

    let result = dispatcher
        .new_position(
            operator_nonce: Zero::zero(),
            position_id: POSITION_ID_1,
            owner_public_key: Zero::zero(),
            owner_account: Zero::zero(),
        );
    assert_panic_with_error(:result, expected_error: "ONLY_OPERATOR");

    let result = dispatcher
        .set_owner_account(
            operator_nonce: Zero::zero(),
            position_id: POSITION_ID_1,
            new_owner_account: Zero::zero(),
            expiration: Time::now(),
        );
    assert_panic_with_error(:result, expected_error: "ONLY_OPERATOR");

    let result = dispatcher
        .set_public_key_request(
            signature: array![].span(),
            position_id: POSITION_ID_1,
            new_public_key: Zero::zero(),
            expiration: Time::now(),
        );
    // Means that any one can call this ABI.
    assert_panic_with_felt_error(:result, expected_error: POSITION_DOESNT_EXIST);

    let result = dispatcher
        .set_public_key(
            operator_nonce: Zero::zero(),
            position_id: POSITION_ID_1,
            new_public_key: Zero::zero(),
            expiration: Time::now(),
        );
    assert_panic_with_error(:result, expected_error: "ONLY_OPERATOR");
}


// Add collateral tests.

#[test]
fn test_successful_register_collateral() {
    // Setup state, token:
    let cfg: PerpetualsInitConfig = Default::default();
    cfg.collateral_cfg.token_cfg.deploy();

    let mut state = initialized_contract_state();
    set_roles(ref :state, cfg: @cfg);
    let mut spy = snforge_std::spy_events();

    // Parameters:
    let asset_id = cfg.collateral_cfg.collateral_id;
    let quantum = COLLATERAL_QUANTUM;
    let token_address = cfg.collateral_cfg.token_cfg.owner;

    // Test.
    cheat_caller_address_once(contract_address: test_address(), caller_address: cfg.app_governor);
    state.register_collateral(:asset_id, :token_address, :quantum);

    // Catch the event.
    let events = spy.get_events().emitted_by(test_address()).events;
    assert_register_collateral_event_with_expected(
        spied_event: events[0], :asset_id, :token_address, :quantum,
    );

    // Check.
    let collateral_config = state.assets.get_collateral_config(collateral_id: asset_id);
    assert!(state.assets.collateral_timely_data.read(asset_id).is_some());
    assert!(state.assets.get_main_collateral_asset_id() == asset_id);
    assert_eq!(collateral_config.status, AssetStatus::ACTIVE);
    assert_eq!(collateral_config.quorum, Zero::zero());
    assert_eq!(collateral_config.risk_factor, Zero::zero());
    assert_eq!(collateral_config.quantum, quantum);
    assert_eq!(state.deposits.get_asset_info(asset_id: asset_id.into()), (token_address, quantum));
}

#[test]
fn test_register_collateral_failures() {
    // Setup:
    let (cfg, state, _) = init_by_dispatcher();
    let dispatcher = IAssetsSafeDispatcher { contract_address: state.address };

    // Parameters:
    // `collateral_id` is already registered in the setup.
    let asset_id = cfg.collateral_cfg.collateral_id;
    let synthetic_id = cfg.synthetic_cfg.synthetic_id;
    let quantum = COLLATERAL_QUANTUM;
    let token_address = cfg.collateral_cfg.token_cfg.owner;

    // Register collateral for the first time.
    cheat_caller_address_once(contract_address: state.address, caller_address: cfg.app_governor);
    dispatcher.register_collateral(:asset_id, :token_address, :quantum).unwrap();

    // Register the same collateral asset.
    cheat_caller_address_once(contract_address: state.address, caller_address: cfg.app_governor);
    let result = dispatcher.register_collateral(:asset_id, :token_address, :quantum);
    assert_panic_with_felt_error(:result, expected_error: ASSET_ALREADY_EXISTS);

    // Register new collateral asset.
    let new_asset_id = AssetIdTrait::new(value: selector!("NEW_COLLATERAL_ASSET_ID"));
    cheat_caller_address_once(contract_address: state.address, caller_address: cfg.app_governor);
    let result = dispatcher.register_collateral(asset_id: new_asset_id, :token_address, :quantum);
    assert_panic_with_felt_error(:result, expected_error: ASSET_ALREADY_EXISTS);

    // Collateral id already register as synthetic.
    cheat_caller_address_once(contract_address: state.address, caller_address: cfg.app_governor);
    dispatcher
        .add_synthetic_asset(
            asset_id: synthetic_id,
            risk_factor_tiers: array![50].span(),
            risk_factor_first_tier_boundary: 1000,
            risk_factor_tier_size: 1,
            quorum: 1,
            resolution: 1,
        )
        .unwrap();

    cheat_caller_address_once(contract_address: state.address, caller_address: cfg.app_governor);
    let result = dispatcher.register_collateral(asset_id: synthetic_id, :token_address, :quantum);
    assert_panic_with_felt_error(:result, expected_error: ASSET_ALREADY_EXISTS);
}

// New position tests.

#[test]
fn test_new_position() {
    // Setup state, token:
    let cfg: PerpetualsInitConfig = Default::default();
    let token_state = cfg.collateral_cfg.token_cfg.deploy();
    let mut state = setup_state_with_active_asset(cfg: @cfg, token_state: @token_state);
    let mut spy = snforge_std::spy_events();

    // Parameters:
    let position_id = POSITION_ID_1;
    let owner_public_key = KEY_PAIR_1().public_key;
    let owner_account = POSITION_OWNER_1();

    // Test.
    cheat_caller_address_once(contract_address: test_address(), caller_address: cfg.operator);
    state
        .new_position(
            operator_nonce: state.nonce(), :position_id, :owner_public_key, :owner_account,
        );

    // Catch the event.
    let events = spy.get_events().emitted_by(test_address()).events;
    assert_new_position_event_with_expected(
        spied_event: events[0], :position_id, :owner_public_key, :owner_account,
    );

    // Check.
    assert_eq!(
        state.positions.get_position_snapshot(:position_id).version.read(), POSITION_VERSION,
    );
    assert_eq!(
        state.positions.get_position_snapshot(:position_id).owner_public_key.read(),
        owner_public_key,
    );
    assert_eq!(
        state.positions.get_position_snapshot(:position_id).owner_account.read(), owner_account,
    );

    let position_tv_tr = state.positions.get_position_tv_tr(:position_id);
    assert!(position_tv_tr.total_value.is_zero());
    assert!(position_tv_tr.total_risk.is_zero());
}

// Set owner account tests.

#[test]
fn test_successful_set_owner_account_request_using_public_key() {
    // Setup state, token and user:
    let cfg: PerpetualsInitConfig = Default::default();
    let token_state = cfg.collateral_cfg.token_cfg.deploy();
    let mut state = setup_state_with_active_asset(cfg: @cfg, token_state: @token_state);
    let user = Default::default();
    init_position(cfg: @cfg, ref :state, :user);

    // Setup parameters:
    let expected_time = Time::now().add(delta: Time::days(1));
    start_cheat_block_timestamp_global(block_timestamp: expected_time.into());
    let expiration = expected_time.add(delta: Time::days(1));

    let set_owner_account_args = SetOwnerAccountArgs {
        public_key: user.get_public_key(),
        new_owner_account: user.address,
        position_id: user.position_id,
        expiration,
    };
    let msg_hash = set_owner_account_args.get_message_hash(public_key: user.get_public_key());
    let signature = user.sign_message(msg_hash);

    // Test:
    cheat_caller_address_once(contract_address: test_address(), caller_address: user.address);
    state
        .positions
        .set_owner_account_request(
            :signature, position_id: user.position_id, new_owner_account: user.address, :expiration,
        );

    // Check:
    let status = state.request_approvals.get_request_status(request_hash: msg_hash);
    assert_eq!(status, RequestStatus::PENDING);
}

#[test]
#[should_panic(expected: 'POSITION_HAS_OWNER_ACCOUNT')]
fn test_set_owner_account_request_position_has_owner() {
    // Setup state, token and user:
    let cfg: PerpetualsInitConfig = Default::default();
    let token_state = cfg.collateral_cfg.token_cfg.deploy();
    let mut state = setup_state_with_active_asset(cfg: @cfg, token_state: @token_state);
    let user = Default::default();
    init_position_with_owner(cfg: @cfg, ref :state, :user);

    // Setup parameters:
    let expected_time = Time::now().add(delta: Time::days(1));
    start_cheat_block_timestamp_global(block_timestamp: expected_time.into());
    let expiration = expected_time.add(delta: Time::days(1));

    let set_owner_account_args = SetOwnerAccountArgs {
        public_key: user.get_public_key(),
        new_owner_account: user.address,
        position_id: user.position_id,
        expiration,
    };
    let msg_hash = set_owner_account_args.get_message_hash(public_key: user.get_public_key());
    let signature = user.sign_message(msg_hash);

    // Test:
    cheat_caller_address_once(contract_address: test_address(), caller_address: user.address);
    state
        .positions
        .set_owner_account_request(
            :signature, position_id: user.position_id, new_owner_account: user.address, :expiration,
        );
}

#[test]
fn test_successful_set_owner_account() {
    // Setup state, token:
    let cfg: PerpetualsInitConfig = Default::default();
    let token_state = cfg.collateral_cfg.token_cfg.deploy();
    let mut state = setup_state_with_active_asset(cfg: @cfg, token_state: @token_state);

    let user: User = Default::default();
    init_position(cfg: @cfg, ref :state, :user);

    // Parameters:
    let position_id = user.position_id;
    let public_key = user.get_public_key();
    let new_owner_account = user.address;
    let expiration = Time::now().add(Time::days(1));

    let set_owner_account_args = SetOwnerAccountArgs {
        position_id, public_key, new_owner_account, expiration,
    };
    let set_owner_account_hash = set_owner_account_args.get_message_hash(user.get_public_key());
    let signature = user.sign_message(set_owner_account_hash);
    cheat_caller_address_once(contract_address: test_address(), caller_address: user.address);
    state
        .positions
        .set_owner_account_request(:signature, :position_id, :new_owner_account, :expiration);

    // Test.
    let mut spy = snforge_std::spy_events();
    cheat_caller_address_once(contract_address: test_address(), caller_address: cfg.operator);
    state
        .positions
        .set_owner_account(
            operator_nonce: state.nonce(), :position_id, :new_owner_account, :expiration,
        );

    // Catch the event.
    let events = spy.get_events().emitted_by(test_address()).events;
    assert_set_owner_account_event_with_expected(
        spied_event: events[0],
        :position_id,
        :public_key,
        :new_owner_account,
        :set_owner_account_hash,
    );

    // Check.
    assert_eq!(
        state.positions.get_position_snapshot(:position_id).owner_account.read(), new_owner_account,
    );
    let status = state.request_approvals.get_request_status(request_hash: set_owner_account_hash);
    assert_eq!(status, RequestStatus::PROCESSED);
}

#[test]
#[should_panic(expected: 'POSITION_HAS_OWNER_ACCOUNT')]
fn test_set_existed_owner_account() {
    // Setup state, token:
    let cfg: PerpetualsInitConfig = Default::default();
    let token_state = cfg.collateral_cfg.token_cfg.deploy();
    let mut state = setup_state_with_active_asset(cfg: @cfg, token_state: @token_state);

    let user: User = Default::default();
    init_position_with_owner(cfg: @cfg, ref :state, :user);

    // Parameters:
    let position_id = POSITION_ID_1;
    let new_owner_account = POSITION_OWNER_1();
    let expiration = Time::now().add(Time::days(1));

    // Test.
    cheat_caller_address_once(contract_address: test_address(), caller_address: cfg.operator);
    state
        .positions
        .set_owner_account(
            operator_nonce: state.nonce(), :position_id, :new_owner_account, :expiration,
        );
}

// Add synthetic asset tests.

#[test]
fn test_successful_add_synthetic_asset() {
    // Setup state, token:
    let cfg: PerpetualsInitConfig = Default::default();
    let token_state = cfg.collateral_cfg.token_cfg.deploy();
    let mut state = setup_state_with_active_asset(cfg: @cfg, token_state: @token_state);
    let mut spy = snforge_std::spy_events();

    // Setup test parameters:
    let synthetic_id_1 = SYNTHETIC_ASSET_ID_2();
    let synthetic_id_2 = SYNTHETIC_ASSET_ID_3();
    let risk_factor_first_tier_boundary = MAX_U128;
    let risk_factor_tier_size = 1;
    let risk_factor_1 = array![10].span();
    let risk_factor_2 = array![20].span();
    let quorum_1 = 1_u8;
    let quorum_2 = 2_u8;
    let resolution_1 = 1_000_000_000;
    let resolution_2 = 2_000_000_000;

    // Test:
    cheat_caller_address_once(contract_address: test_address(), caller_address: cfg.app_governor);
    state
        .add_synthetic_asset(
            asset_id: synthetic_id_1,
            risk_factor_tiers: risk_factor_1,
            :risk_factor_first_tier_boundary,
            :risk_factor_tier_size,
            quorum: quorum_1,
            resolution: resolution_1,
        );

    cheat_caller_address_once(contract_address: test_address(), caller_address: cfg.app_governor);
    state
        .add_synthetic_asset(
            asset_id: synthetic_id_2,
            risk_factor_tiers: risk_factor_2,
            :risk_factor_first_tier_boundary,
            :risk_factor_tier_size,
            quorum: quorum_2,
            resolution: resolution_2,
        );

    // Catch the event.
    let events = spy.get_events().emitted_by(test_address()).events;
    assert_add_synthetic_event_with_expected(
        spied_event: events[0],
        asset_id: synthetic_id_1,
        risk_factor_tiers: risk_factor_1,
        :risk_factor_first_tier_boundary,
        :risk_factor_tier_size,
        resolution: resolution_1,
        quorum: quorum_1,
    );

    // Check:
    check_synthetic_asset(
        state: @state,
        synthetic_id: synthetic_id_1,
        status: AssetStatus::PENDING,
        risk_factor_tiers: risk_factor_1,
        :risk_factor_first_tier_boundary,
        :risk_factor_tier_size,
        quorum: quorum_1,
        resolution: resolution_1,
        price: Zero::zero(),
        last_price_update: Zero::zero(),
        funding_index: Zero::zero(),
    );
    check_synthetic_asset(
        state: @state,
        synthetic_id: synthetic_id_2,
        status: AssetStatus::PENDING,
        risk_factor_tiers: risk_factor_2,
        :risk_factor_first_tier_boundary,
        :risk_factor_tier_size,
        quorum: quorum_2,
        resolution: resolution_2,
        price: Zero::zero(),
        last_price_update: Zero::zero(),
        funding_index: Zero::zero(),
    );
}

#[test]
#[should_panic(expected: 'SYNTHETIC_ALREADY_EXISTS')]
fn test_add_synthetic_asset_existed_asset() {
    // Setup state, token:
    let cfg: PerpetualsInitConfig = Default::default();
    let token_state = cfg.collateral_cfg.token_cfg.deploy();
    let mut state = setup_state_with_active_asset(cfg: @cfg, token_state: @token_state);

    // Test:
    cheat_caller_address_once(contract_address: test_address(), caller_address: cfg.app_governor);
    state
        .add_synthetic_asset(
            // Setup state already added `SYNTHETIC_ASSET_ID_1`.
            asset_id: SYNTHETIC_ASSET_ID_1(),
            risk_factor_tiers: array![10].span(),
            risk_factor_first_tier_boundary: MAX_U128,
            risk_factor_tier_size: 1,
            quorum: 13,
            resolution: 10000000,
        );
}

// Deactivate synthetic asset tests.

#[test]
fn test_successful_deactivate_synthetic_asset() {
    // Setup state, token and user:
    let cfg: PerpetualsInitConfig = Default::default();
    let token_state = cfg.collateral_cfg.token_cfg.deploy();
    let mut state = setup_state_with_active_asset(cfg: @cfg, token_state: @token_state);
    let mut spy = snforge_std::spy_events();

    // Setup parameters:
    let synthetic_id = cfg.synthetic_cfg.synthetic_id;
    assert!(
        state
            .assets
            .synthetic_config
            .entry(synthetic_id)
            .read()
            .unwrap()
            .status == AssetStatus::ACTIVE,
    );

    // Test:
    cheat_caller_address_once(contract_address: test_address(), caller_address: cfg.app_governor);
    state.deactivate_synthetic(:synthetic_id);

    // Catch the event.
    let events = spy.get_events().emitted_by(test_address()).events;
    assert_deactivate_synthetic_asset_event_with_expected(
        spied_event: events[0], asset_id: synthetic_id,
    );

    // Check:
    assert!(
        state
            .assets
            .synthetic_config
            .entry(synthetic_id)
            .read()
            .unwrap()
            .status == AssetStatus::DEACTIVATED,
    );
}

#[test]
#[should_panic(expected: 'SYNTHETIC_NOT_EXISTS')]
fn test_deactivate_nonexistent_synthetic_asset() {
    // Setup state, token and user:
    let cfg: PerpetualsInitConfig = Default::default();
    let token_state = cfg.collateral_cfg.token_cfg.deploy();
    let mut state = setup_state_with_active_asset(cfg: @cfg, token_state: @token_state);
    // Setup parameters:
    let synthetic_id = SYNTHETIC_ASSET_ID_2();

    // Test:
    cheat_caller_address_once(contract_address: test_address(), caller_address: cfg.app_governor);
    state.deactivate_synthetic(:synthetic_id);
}


#[test]
fn test_successful_withdraw() {
    // Set a non zero timestamp as Time::now().
    start_cheat_block_timestamp_global(block_timestamp: Time::now().add(Time::seconds(100)).into());

    // Setup state, token and user:
    let cfg: PerpetualsInitConfig = Default::default();
    let token_state = cfg.collateral_cfg.token_cfg.deploy();
    let mut state = setup_state_with_active_asset(cfg: @cfg, token_state: @token_state);
    let user = Default::default();
    init_position(cfg: @cfg, ref :state, :user);

    // Setup parameters:
    let expiration = Time::now().add(Time::days(1));

    let withdraw_args = WithdrawArgs {
        position_id: user.position_id,
        salt: user.salt_counter,
        expiration,
        collateral_id: cfg.collateral_cfg.collateral_id,
        amount: WITHDRAW_AMOUNT,
        recipient: user.address,
    };
    let hash = withdraw_args.get_message_hash(user.get_public_key());
    let signature = user.sign_message(hash);
    let operator_nonce = state.nonce();

    let contract_state_balance = token_state.balance_of(test_address());
    assert_eq!(contract_state_balance, CONTRACT_INIT_BALANCE.into());

    let mut spy = snforge_std::spy_events();
    // Test:
    state
        .withdraw_request(
            :signature,
            recipient: withdraw_args.recipient,
            position_id: withdraw_args.position_id,
            collateral_id: withdraw_args.collateral_id,
            amount: withdraw_args.amount,
            expiration: withdraw_args.expiration,
            salt: withdraw_args.salt,
        );
    cheat_caller_address_once(contract_address: test_address(), caller_address: cfg.operator);
    state
        .withdraw(
            :operator_nonce,
            recipient: withdraw_args.recipient,
            position_id: withdraw_args.position_id,
            collateral_id: withdraw_args.collateral_id,
            amount: withdraw_args.amount,
            expiration: withdraw_args.expiration,
            salt: withdraw_args.salt,
        );

    // Catch the event.
    let events = spy.get_events().emitted_by(test_address()).events;
    assert_withdraw_request_event_with_expected(
        spied_event: events[0],
        position_id: withdraw_args.position_id,
        recipient: withdraw_args.recipient,
        collateral_id: withdraw_args.collateral_id,
        amount: withdraw_args.amount,
        expiration: withdraw_args.expiration,
        withdraw_request_hash: hash,
    );
    assert_withdraw_event_with_expected(
        spied_event: events[1],
        position_id: withdraw_args.position_id,
        recipient: withdraw_args.recipient,
        collateral_id: withdraw_args.collateral_id,
        amount: withdraw_args.amount,
        expiration: withdraw_args.expiration,
        withdraw_request_hash: hash,
    );
    // Check:
    let user_balance = token_state.balance_of(user.address);
    let onchain_amount = (WITHDRAW_AMOUNT * COLLATERAL_QUANTUM);
    assert_eq!(user_balance, onchain_amount.into());
    let contract_state_balance = token_state.balance_of(test_address());
    assert_eq!(contract_state_balance, (CONTRACT_INIT_BALANCE - onchain_amount.into()).into());
    assert_eq!(
        state
            .positions
            .get_provisional_balance(
                position: state.positions.get_position_snapshot(position_id: user.position_id),
                collateral_id: cfg.collateral_cfg.collateral_id,
            ),
        COLLATERAL_BALANCE_AMOUNT.into() - WITHDRAW_AMOUNT.into(),
    );
}

// Deposit tests.

#[test]
fn test_successful_deposit() {
    // Setup state, token and user:
    let cfg: PerpetualsInitConfig = Default::default();
    let token_state = cfg.collateral_cfg.token_cfg.deploy();
    let mut state = setup_state_with_active_asset(cfg: @cfg, token_state: @token_state);
    let collateral_cfg_id = cfg.collateral_cfg.collateral_id.into();
    let user = Default::default();
    let user_deposit_amount = DEPOSIT_AMOUNT.into() * cfg.collateral_cfg.quantum.into();
    init_position(cfg: @cfg, ref :state, :user);

    // Fund user.
    token_state.fund(recipient: user.address, amount: USER_INIT_BALANCE.try_into().unwrap());
    token_state.approve(owner: user.address, spender: test_address(), amount: user_deposit_amount);

    // Setup parameters:
    let expected_time = Time::now().add(delta: Time::days(1));
    start_cheat_block_timestamp_global(block_timestamp: expected_time.into());

    // Check before deposit:
    validate_balance(token_state, user.address, USER_INIT_BALANCE.try_into().unwrap());
    validate_balance(token_state, test_address(), CONTRACT_INIT_BALANCE.try_into().unwrap());
    let mut spy = snforge_std::spy_events();

    // Test:
    cheat_caller_address_once(contract_address: test_address(), caller_address: user.address);
    state
        .deposit(
            beneficiary: user.position_id.value,
            asset_id: collateral_cfg_id,
            quantized_amount: DEPOSIT_AMOUNT.into(),
            salt: user.salt_counter,
        );
    let deposit_hash = deposit_hash(
        depositor: user.address,
        beneficiary: user.position_id.value,
        asset_id: collateral_cfg_id,
        quantized_amount: DEPOSIT_AMOUNT.into(),
        salt: user.salt_counter,
    );

    // Catch the event.
    let events = spy.get_events().emitted_by(test_address()).events;
    assert_deposit_event_with_expected(
        spied_event: events[0],
        beneficiary: user.position_id.value,
        depositing_address: user.address,
        asset_id: collateral_cfg_id,
        quantized_amount: DEPOSIT_AMOUNT.into(),
        unquantized_amount: DEPOSIT_AMOUNT.into() * COLLATERAL_QUANTUM.into(),
        deposit_request_hash: deposit_hash,
    );

    // Check after deposit:
    validate_balance(
        token_state, user.address, (USER_INIT_BALANCE - user_deposit_amount).try_into().unwrap(),
    );
    validate_balance(
        token_state,
        test_address(),
        (CONTRACT_INIT_BALANCE + user_deposit_amount).try_into().unwrap(),
    );
    let status = state.deposits.get_deposit_status(:deposit_hash);
    if let DepositStatus::PENDING(timestamp) = status {
        assert_eq!(timestamp, expected_time);
    } else {
        panic!("Deposit not found");
    }
}

#[test]
#[should_panic(expected: 'DEPOSIT_ALREADY_REGISTERED')]
fn test_deposit_already_registered() {
    // Setup state, token and user:
    let cfg: PerpetualsInitConfig = Default::default();
    let token_state = cfg.collateral_cfg.token_cfg.deploy();
    let mut state = setup_state_with_active_asset(cfg: @cfg, token_state: @token_state);
    let collateral_cfg_id = cfg.collateral_cfg.collateral_id.into();
    let user = Default::default();
    let user_deposit_amount = DEPOSIT_AMOUNT.into() * cfg.collateral_cfg.quantum.into();
    init_position(cfg: @cfg, ref :state, :user);

    // Fund user.
    token_state.fund(recipient: user.address, amount: USER_INIT_BALANCE.try_into().unwrap());
    token_state.approve(owner: user.address, spender: test_address(), amount: user_deposit_amount);

    // Setup parameters:
    let expected_time = Time::now().add(delta: Time::days(1));
    start_cheat_block_timestamp_global(block_timestamp: expected_time.into());

    // Test:
    cheat_caller_address_once(contract_address: test_address(), caller_address: user.address);
    state
        .deposit(
            beneficiary: user.position_id.value,
            asset_id: collateral_cfg_id,
            quantized_amount: DEPOSIT_AMOUNT.into(),
            salt: user.salt_counter,
        );
    state
        .deposit(
            beneficiary: user.position_id.value,
            asset_id: collateral_cfg_id,
            quantized_amount: DEPOSIT_AMOUNT.into(),
            salt: user.salt_counter,
        );
}

#[test]
fn test_successful_process_deposit() {
    // Setup state, token and user:
    let cfg: PerpetualsInitConfig = Default::default();
    let token_state = cfg.collateral_cfg.token_cfg.deploy();
    let mut state = setup_state_with_active_asset(cfg: @cfg, token_state: @token_state);
    let user = Default::default();
    init_position(cfg: @cfg, ref :state, :user);
    let collateral_cfg_id = cfg.collateral_cfg.collateral_id.into();
    let user_deposit_amount = DEPOSIT_AMOUNT.into() * cfg.collateral_cfg.quantum.into();

    // Fund user.
    token_state.fund(recipient: user.address, amount: USER_INIT_BALANCE.try_into().unwrap());
    token_state.approve(owner: user.address, spender: test_address(), amount: user_deposit_amount);

    // Setup parameters:
    start_cheat_block_timestamp_global(
        block_timestamp: Time::now().add(delta: Time::seconds(1000)).into(),
    );

    cheat_caller_address_once(contract_address: test_address(), caller_address: user.address);
    state
        .deposit(
            beneficiary: user.position_id.value,
            asset_id: collateral_cfg_id,
            quantized_amount: DEPOSIT_AMOUNT.into(),
            salt: user.salt_counter,
        );
    let deposit_hash = deposit_hash(
        depositor: user.address,
        beneficiary: user.position_id.value,
        asset_id: collateral_cfg_id,
        quantized_amount: DEPOSIT_AMOUNT.into(),
        salt: user.salt_counter,
    );
    let mut spy = snforge_std::spy_events();

    cheat_caller_address_once(contract_address: test_address(), caller_address: cfg.operator);
    state
        .process_deposit(
            operator_nonce: state.nonce(),
            depositor: user.address,
            position_id: user.position_id,
            collateral_id: collateral_cfg_id.into(),
            amount: DEPOSIT_AMOUNT,
            salt: user.salt_counter,
        );

    // Catch the event.
    let events = spy.get_events().emitted_by(test_address()).events;
    assert_deposit_processed_event_with_expected(
        spied_event: events[0],
        beneficiary: user.position_id.value,
        depositing_address: user.address,
        asset_id: collateral_cfg_id,
        quantized_amount: DEPOSIT_AMOUNT.into(),
        unquantized_amount: DEPOSIT_AMOUNT.into() * COLLATERAL_QUANTUM.into(),
        deposit_request_hash: deposit_hash,
    );

    let status = state.deposits.get_deposit_status(:deposit_hash);
    assert_eq!(status, DepositStatus::DONE, "Deposit not processed");
}

// Cancel deposit tests.

#[test]
fn test_successful_cancel_deposit() {
    // Setup state, token and user:
    let cfg: PerpetualsInitConfig = Default::default();
    let token_state = cfg.collateral_cfg.token_cfg.deploy();
    let mut state = setup_state_with_active_asset(cfg: @cfg, token_state: @token_state);
    let user = Default::default();
    init_position(cfg: @cfg, ref :state, :user);
    let collateral_cfg_id = cfg.collateral_cfg.collateral_id.into();
    let user_deposit_amount = DEPOSIT_AMOUNT.into() * cfg.collateral_cfg.quantum.into();

    // Fund user.
    token_state.fund(recipient: user.address, amount: USER_INIT_BALANCE.try_into().unwrap());
    token_state.approve(owner: user.address, spender: test_address(), amount: user_deposit_amount);

    // Setup parameters:
    start_cheat_block_timestamp_global(
        block_timestamp: Time::now().add(delta: Time::days(1)).into(),
    );
    cheat_caller_address_once(contract_address: test_address(), caller_address: user.address);
    state
        .deposit(
            beneficiary: user.position_id.value,
            asset_id: collateral_cfg_id,
            quantized_amount: DEPOSIT_AMOUNT.into(),
            salt: user.salt_counter,
        );
    let deposit_hash = deposit_hash(
        depositor: user.address,
        beneficiary: user.position_id.value,
        asset_id: collateral_cfg_id,
        quantized_amount: DEPOSIT_AMOUNT.into(),
        salt: user.salt_counter,
    );
    let mut spy = snforge_std::spy_events();

    // Check before cancel deposit:
    validate_balance(
        token_state, user.address, (USER_INIT_BALANCE - user_deposit_amount).try_into().unwrap(),
    );
    validate_balance(
        token_state,
        test_address(),
        (CONTRACT_INIT_BALANCE + user_deposit_amount).try_into().unwrap(),
    );

    // Test:
    start_cheat_block_timestamp_global(
        block_timestamp: Time::now().add(delta: Time::weeks(2)).into(),
    );
    state
        .cancel_deposit(
            beneficiary: user.position_id.value,
            asset_id: collateral_cfg_id,
            quantized_amount: DEPOSIT_AMOUNT.into(),
            salt: user.salt_counter,
        );

    // Catch the event.
    let events = spy.get_events().emitted_by(test_address()).events;
    assert_deposit_canceled_event_with_expected(
        spied_event: events[0],
        beneficiary: user.position_id.value,
        depositing_address: user.address,
        asset_id: collateral_cfg_id,
        quantized_amount: DEPOSIT_AMOUNT.into(),
        unquantized_amount: DEPOSIT_AMOUNT.into() * COLLATERAL_QUANTUM.into(),
        deposit_request_hash: deposit_hash,
    );

    // Check after deposit cancellation:
    validate_balance(token_state, user.address, USER_INIT_BALANCE.try_into().unwrap());
    validate_balance(token_state, test_address(), CONTRACT_INIT_BALANCE.try_into().unwrap());
}

#[test]
#[should_panic(expected: 'DEPOSIT_NOT_REGISTERED')]
fn test_cancel_non_registered_deposit() {
    // Setup state, token and user:
    let cfg: PerpetualsInitConfig = Default::default();
    let token_state = cfg.collateral_cfg.token_cfg.deploy();
    let mut state = setup_state_with_active_asset(cfg: @cfg, token_state: @token_state);
    let user = Default::default();
    init_position(cfg: @cfg, ref :state, :user);

    cheat_caller_address_once(contract_address: test_address(), caller_address: user.address);
    state
        .cancel_deposit(
            beneficiary: user.position_id.value,
            asset_id: cfg.collateral_cfg.collateral_id.into(),
            quantized_amount: DEPOSIT_AMOUNT.into(),
            salt: user.salt_counter,
        );
}

#[test]
#[should_panic(expected: 'DEPOSIT_NOT_REGISTERED')]
fn test_cancel_deposit_different_hash() {
    // Setup state, token and user:
    let cfg: PerpetualsInitConfig = Default::default();
    let token_state = cfg.collateral_cfg.token_cfg.deploy();
    let mut state = setup_state_with_active_asset(cfg: @cfg, token_state: @token_state);
    let user = Default::default();
    init_position(cfg: @cfg, ref :state, :user);
    let collateral_cfg_id = cfg.collateral_cfg.collateral_id.into();
    let user_deposit_amount = DEPOSIT_AMOUNT.into() * cfg.collateral_cfg.quantum.into();

    // Fund user.
    token_state.fund(recipient: user.address, amount: USER_INIT_BALANCE.try_into().unwrap());
    token_state.approve(owner: user.address, spender: test_address(), amount: user_deposit_amount);

    // Setup parameters:
    start_cheat_block_timestamp_global(
        block_timestamp: Time::now().add(delta: Time::days(1)).into(),
    );
    cheat_caller_address_once(contract_address: test_address(), caller_address: user.address);
    state
        .deposit(
            beneficiary: user.position_id.value,
            asset_id: collateral_cfg_id,
            quantized_amount: DEPOSIT_AMOUNT.into(),
            salt: user.salt_counter,
        );

    state
        .cancel_deposit(
            beneficiary: user.position_id.value,
            asset_id: collateral_cfg_id,
            quantized_amount: DEPOSIT_AMOUNT.into(),
            salt: user.salt_counter + 1,
        );
}

#[test]
#[should_panic(expected: 'DEPOSIT_ALREADY_PROCESSED')]
fn test_cancel_already_done_deposit() {
    // Setup state, token and user:
    let cfg: PerpetualsInitConfig = Default::default();
    let token_state = cfg.collateral_cfg.token_cfg.deploy();
    let mut state = setup_state_with_active_asset(cfg: @cfg, token_state: @token_state);
    let user = Default::default();
    init_position(cfg: @cfg, ref :state, :user);
    let collateral_cfg_id = cfg.collateral_cfg.collateral_id.into();
    let user_deposit_amount = DEPOSIT_AMOUNT.into() * cfg.collateral_cfg.quantum.into();

    // Fund user.
    token_state.fund(recipient: user.address, amount: USER_INIT_BALANCE.try_into().unwrap());
    token_state.approve(owner: user.address, spender: test_address(), amount: user_deposit_amount);

    // Setup parameters:
    start_cheat_block_timestamp_global(
        block_timestamp: Time::now().add(delta: Time::seconds(1000)).into(),
    );

    // Test:
    cheat_caller_address_once(contract_address: test_address(), caller_address: user.address);
    state
        .deposit(
            beneficiary: user.position_id.value,
            asset_id: collateral_cfg_id,
            quantized_amount: DEPOSIT_AMOUNT.into(),
            salt: user.salt_counter,
        );

    cheat_caller_address_once(contract_address: test_address(), caller_address: cfg.operator);
    state
        .process_deposit(
            operator_nonce: state.nonce(),
            depositor: user.address,
            position_id: user.position_id,
            collateral_id: collateral_cfg_id.into(),
            amount: DEPOSIT_AMOUNT,
            salt: user.salt_counter,
        );

    start_cheat_block_timestamp_global(
        block_timestamp: Time::now().add(delta: Time::weeks(2)).into(),
    );
    cheat_caller_address_once(contract_address: test_address(), caller_address: user.address);
    state
        .cancel_deposit(
            beneficiary: user.position_id.value,
            asset_id: collateral_cfg_id,
            quantized_amount: DEPOSIT_AMOUNT.into(),
            salt: user.salt_counter,
        );
}

#[test]
#[should_panic(expected: 'DEPOSIT_ALREADY_CANCELED')]
fn test_double_cancel_deposit() {
    // Setup state, token and user:
    let cfg: PerpetualsInitConfig = Default::default();
    let token_state = cfg.collateral_cfg.token_cfg.deploy();
    let mut state = setup_state_with_active_asset(cfg: @cfg, token_state: @token_state);
    let user = Default::default();
    init_position(cfg: @cfg, ref :state, :user);
    let collateral_cfg_id = cfg.collateral_cfg.collateral_id.into();
    let user_deposit_amount = DEPOSIT_AMOUNT.into() * cfg.collateral_cfg.quantum.into();

    // Fund user.
    token_state.fund(recipient: user.address, amount: USER_INIT_BALANCE.try_into().unwrap());
    token_state.approve(owner: user.address, spender: test_address(), amount: user_deposit_amount);

    // Setup parameters:
    start_cheat_block_timestamp_global(
        block_timestamp: Time::now().add(delta: Time::days(1)).into(),
    );

    // Test:
    cheat_caller_address_once(contract_address: test_address(), caller_address: user.address);
    state
        .deposit(
            beneficiary: user.position_id.value,
            asset_id: collateral_cfg_id,
            quantized_amount: DEPOSIT_AMOUNT.into(),
            salt: user.salt_counter,
        );

    start_cheat_block_timestamp_global(
        block_timestamp: Time::now().add(delta: Time::weeks(2)).into(),
    );
    state
        .cancel_deposit(
            beneficiary: user.position_id.value,
            asset_id: collateral_cfg_id,
            quantized_amount: DEPOSIT_AMOUNT.into(),
            salt: user.salt_counter,
        );
    state
        .cancel_deposit(
            beneficiary: user.position_id.value,
            asset_id: collateral_cfg_id,
            quantized_amount: DEPOSIT_AMOUNT.into(),
            salt: user.salt_counter,
        );
}

#[test]
#[should_panic(expected: 'DEPOSIT_NOT_CANCELABLE')]
fn test_cancel_deposit_before_cancellation_delay_passed() {
    // Setup state, token and user:
    let cfg: PerpetualsInitConfig = Default::default();
    let token_state = cfg.collateral_cfg.token_cfg.deploy();
    let mut state = setup_state_with_active_asset(cfg: @cfg, token_state: @token_state);
    let user = Default::default();
    init_position(cfg: @cfg, ref :state, :user);
    let collateral_cfg_id = cfg.collateral_cfg.collateral_id.into();
    let user_deposit_amount = DEPOSIT_AMOUNT.into() * cfg.collateral_cfg.quantum.into();

    // Fund user.
    token_state.fund(recipient: user.address, amount: USER_INIT_BALANCE.try_into().unwrap());
    token_state.approve(owner: user.address, spender: test_address(), amount: user_deposit_amount);

    // Setup parameters:
    start_cheat_block_timestamp_global(
        block_timestamp: Time::now().add(delta: Time::days(1)).into(),
    );

    // Test:
    cheat_caller_address_once(contract_address: test_address(), caller_address: user.address);
    state
        .deposit(
            beneficiary: user.position_id.value,
            asset_id: collateral_cfg_id,
            quantized_amount: DEPOSIT_AMOUNT.into(),
            salt: user.salt_counter,
        );

    state
        .cancel_deposit(
            beneficiary: user.position_id.value,
            asset_id: collateral_cfg_id,
            quantized_amount: DEPOSIT_AMOUNT.into(),
            salt: user.salt_counter,
        );
}

// Trade tests.

#[test]
fn test_successful_trade() {
    // Setup state, token and user:
    let cfg: PerpetualsInitConfig = Default::default();
    let token_state = cfg.collateral_cfg.token_cfg.deploy();
    let mut state = setup_state_with_active_asset(cfg: @cfg, token_state: @token_state);

    let user_a = Default::default();
    init_position(cfg: @cfg, ref :state, user: user_a);

    let user_b = UserTrait::new(position_id: POSITION_ID_2, key_pair: KEY_PAIR_2());
    init_position(cfg: @cfg, ref :state, user: user_b);

    // Test params:
    let BASE = 10;
    let QUOTE = -5;
    let FEE = 1;

    // Setup parameters:
    let expiration = Time::now().add(delta: Time::days(1));

    let collateral_id = cfg.collateral_cfg.collateral_id;
    let synthetic_id = cfg.synthetic_cfg.synthetic_id;

    let order_a = Order {
        position_id: user_a.position_id,
        salt: user_a.salt_counter,
        base_asset_id: synthetic_id,
        base_amount: BASE,
        quote_asset_id: collateral_id,
        quote_amount: QUOTE,
        fee_asset_id: collateral_id,
        fee_amount: FEE,
        expiration,
    };

    let order_b = Order {
        position_id: user_b.position_id,
        base_asset_id: synthetic_id,
        base_amount: -BASE,
        quote_asset_id: collateral_id,
        quote_amount: -QUOTE,
        fee_asset_id: collateral_id,
        fee_amount: FEE,
        expiration,
        salt: user_b.salt_counter,
    };

    let hash_a = order_a.get_message_hash(user_a.get_public_key());
    let hash_b = order_b.get_message_hash(user_b.get_public_key());
    let signature_a = user_a.sign_message(hash_a);
    let signature_b = user_b.sign_message(hash_b);
    let operator_nonce = state.nonce();

    let mut spy = snforge_std::spy_events();
    // Test:
    cheat_caller_address_once(contract_address: test_address(), caller_address: cfg.operator);
    state
        .trade(
            :operator_nonce,
            :signature_a,
            :signature_b,
            :order_a,
            :order_b,
            actual_amount_base_a: BASE,
            actual_amount_quote_a: QUOTE,
            actual_fee_a: FEE,
            actual_fee_b: FEE,
        );

    // Catch the event.
    let events = spy.get_events().emitted_by(test_address()).events;
    assert_trade_event_with_expected(
        spied_event: events[0],
        order_a_position_id: user_a.position_id,
        order_a_base_asset_id: synthetic_id,
        order_a_base_amount: BASE,
        order_a_quote_asset_id: collateral_id,
        order_a_quote_amount: QUOTE,
        fee_a_asset_id: collateral_id,
        fee_a_amount: FEE,
        order_b_position_id: user_b.position_id,
        order_b_base_asset_id: synthetic_id,
        order_b_base_amount: -BASE,
        order_b_quote_asset_id: collateral_id,
        order_b_quote_amount: -QUOTE,
        fee_b_asset_id: collateral_id,
        fee_b_amount: FEE,
        actual_amount_base_a: BASE,
        actual_amount_quote_a: QUOTE,
        actual_fee_a: FEE,
        actual_fee_b: FEE,
        order_a_hash: hash_a,
        order_b_hash: hash_b,
    );

    // Check:
    let position_a = state.positions.get_position_snapshot(position_id: user_a.position_id);
    let user_a_collateral_balance = state
        .positions
        .get_provisional_balance(position: position_a, :collateral_id);
    let user_a_synthetic_balance = state
        .positions
        .get_synthetic_balance(position: position_a, :synthetic_id);
    assert_eq!(
        user_a_collateral_balance, (COLLATERAL_BALANCE_AMOUNT.into() - FEE.into() + QUOTE.into()),
    );
    assert_eq!(user_a_synthetic_balance, (BASE).into());

    let position_b = state.positions.get_position_snapshot(position_id: user_b.position_id);
    let user_b_collateral_balance = state
        .positions
        .get_provisional_balance(position: position_b, :collateral_id);
    let user_b_synthetic_balance = state
        .positions
        .get_synthetic_balance(position: position_b, :synthetic_id);
    assert_eq!(
        user_b_collateral_balance, (COLLATERAL_BALANCE_AMOUNT.into() - FEE.into() - QUOTE.into()),
    );
    assert_eq!(user_b_synthetic_balance, (-BASE).into());

    let position = state.positions.get_position_snapshot(position_id: Positions::FEE_POSITION);
    let fee_position_balance = state.positions.get_provisional_balance(:position, :collateral_id);
    assert_eq!(fee_position_balance, (FEE + FEE).into());
}

#[test]
#[should_panic(expected: 'INVALID_WRONG_AMOUNT_SIGN')]
fn test_invalid_trade_same_base_signs() {
    // Setup state, token and user:
    let cfg: PerpetualsInitConfig = Default::default();
    let token_state = cfg.collateral_cfg.token_cfg.deploy();
    let mut state = setup_state_with_active_asset(cfg: @cfg, token_state: @token_state);

    let user_a = Default::default();
    init_position(cfg: @cfg, ref :state, user: user_a);

    let user_b = UserTrait::new(position_id: POSITION_ID_2, key_pair: KEY_PAIR_2());
    init_position(cfg: @cfg, ref :state, user: user_b);

    // Test params:
    let BASE = 10;
    let QUOTE = -5;
    let FEE = 1;

    // Setup parameters:
    let expiration = Time::now().add(delta: Time::days(1));

    let collateral_id = cfg.collateral_cfg.collateral_id;
    let synthetic_id = cfg.synthetic_cfg.synthetic_id;

    let order_a = Order {
        position_id: user_a.position_id,
        salt: user_a.salt_counter,
        base_asset_id: synthetic_id,
        base_amount: BASE,
        quote_asset_id: collateral_id,
        quote_amount: QUOTE,
        fee_asset_id: collateral_id,
        fee_amount: FEE,
        expiration,
    };

    // Wrong sign for base amount.
    let order_b = Order {
        position_id: user_b.position_id,
        salt: user_b.salt_counter,
        base_asset_id: synthetic_id,
        base_amount: BASE,
        quote_asset_id: collateral_id,
        quote_amount: -QUOTE,
        fee_asset_id: collateral_id,
        fee_amount: FEE,
        expiration,
    };

    let signature_a = user_a.sign_message(order_a.get_message_hash(user_a.get_public_key()));
    let signature_b = user_b.sign_message(order_b.get_message_hash(user_b.get_public_key()));
    let operator_nonce = state.nonce();

    // Test:
    cheat_caller_address_once(contract_address: test_address(), caller_address: cfg.operator);
    state
        .trade(
            :operator_nonce,
            :signature_a,
            :signature_b,
            :order_a,
            :order_b,
            actual_amount_base_a: BASE,
            actual_amount_quote_a: QUOTE,
            actual_fee_a: FEE,
            actual_fee_b: FEE,
        );
}

#[test]
fn test_successful_withdraw_request_with_public_key() {
    // Setup state, token and user:
    let cfg: PerpetualsInitConfig = Default::default();
    let token_state = cfg.collateral_cfg.token_cfg.deploy();
    let mut state = setup_state_with_active_asset(cfg: @cfg, token_state: @token_state);
    let user = Default::default();
    init_position(cfg: @cfg, ref :state, :user);
    let recipient = UserTrait::new(position_id: POSITION_ID_2, key_pair: KEY_PAIR_2());

    // Setup parameters:
    start_cheat_block_timestamp_global(
        block_timestamp: Time::now().add(delta: Time::days(1)).into(),
    );
    let expiration = Time::now().add(delta: Time::days(1));

    let withdraw_args = WithdrawArgs {
        position_id: user.position_id,
        salt: user.salt_counter,
        expiration,
        collateral_id: cfg.collateral_cfg.collateral_id,
        amount: WITHDRAW_AMOUNT,
        recipient: recipient.address,
    };
    let msg_hash = withdraw_args.get_message_hash(public_key: user.get_public_key());
    let signature = user.sign_message(message: msg_hash);

    // Test:
    cheat_caller_address_once(contract_address: test_address(), caller_address: user.address);
    state
        .withdraw_request(
            :signature,
            recipient: withdraw_args.recipient,
            position_id: withdraw_args.position_id,
            collateral_id: withdraw_args.collateral_id,
            amount: withdraw_args.amount,
            expiration: withdraw_args.expiration,
            salt: withdraw_args.salt,
        );

    // Check:
    let status = state.request_approvals.get_request_status(request_hash: msg_hash);
    assert_eq!(status, RequestStatus::PENDING);
}

#[test]
fn test_successful_withdraw_request_with_owner() {
    // Setup state, token and user:
    let cfg: PerpetualsInitConfig = Default::default();
    let token_state = cfg.collateral_cfg.token_cfg.deploy();
    let mut state = setup_state_with_active_asset(cfg: @cfg, token_state: @token_state);
    let user = Default::default();
    init_position_with_owner(cfg: @cfg, ref :state, :user);
    let recipient = UserTrait::new(position_id: POSITION_ID_2, key_pair: KEY_PAIR_2());

    // Setup parameters:
    start_cheat_block_timestamp_global(
        block_timestamp: Time::now().add(delta: Time::days(1)).into(),
    );
    let expiration = Time::now().add(delta: Time::days(1));

    let withdraw_args = WithdrawArgs {
        position_id: user.position_id,
        salt: user.salt_counter,
        recipient: recipient.address,
        collateral_id: cfg.collateral_cfg.collateral_id,
        amount: WITHDRAW_AMOUNT,
        expiration,
    };
    let msg_hash = withdraw_args.get_message_hash(public_key: user.get_public_key());
    let signature = user.sign_message(message: msg_hash);

    // Test:
    cheat_caller_address_once(contract_address: test_address(), caller_address: user.address);
    state
        .withdraw_request(
            :signature,
            recipient: withdraw_args.recipient,
            position_id: withdraw_args.position_id,
            collateral_id: withdraw_args.collateral_id,
            amount: withdraw_args.amount,
            expiration: withdraw_args.expiration,
            salt: withdraw_args.salt,
        );

    // Check:
    let status = state.request_approvals.get_request_status(request_hash: msg_hash);
    assert_eq!(status, RequestStatus::PENDING);
}

// Deleverage tests.

#[test]
fn test_successful_deleverage() {
    // Setup state, token and user:
    let cfg: PerpetualsInitConfig = Default::default();
    let token_state = cfg.collateral_cfg.token_cfg.deploy();
    let mut state = setup_state_with_active_asset(cfg: @cfg, token_state: @token_state);

    let deleveraged = Default::default();
    init_position(cfg: @cfg, ref :state, user: deleveraged);
    add_synthetic_to_position(
        ref :state,
        synthetic_id: cfg.synthetic_cfg.synthetic_id,
        position_id: deleveraged.position_id,
        // To make the position deleveragable, the total value must be negative, which requires a
        // negative synthetic balance.
        balance: -2 * SYNTHETIC_BALANCE_AMOUNT,
    );

    let deleverager = UserTrait::new(position_id: POSITION_ID_2, key_pair: KEY_PAIR_2());
    init_position(cfg: @cfg, ref :state, user: deleverager);
    add_synthetic_to_position(
        ref :state,
        synthetic_id: cfg.synthetic_cfg.synthetic_id,
        position_id: deleverager.position_id,
        balance: SYNTHETIC_BALANCE_AMOUNT,
    );

    // Test params:
    let operator_nonce = state.nonce();
    // For a fair deleverage, the TV/TR ratio of the deleveraged position should remain the same
    // before and after the deleverage. This is the reasoning behind the choice
    // of QUOTE and BASE.
    let BASE = 10;
    let QUOTE = -500;

    let collateral_id = cfg.collateral_cfg.collateral_id;
    let synthetic_id = cfg.synthetic_cfg.synthetic_id;

    // State change:
    //                            TV                            TR                          TV/TR
    //                COLLATERAL*1 + SYNTHETIC*PRICE        |SYNTHETIC*PRICE*RISK|
    // Deleveraged before:     2000-40*100=-2000              40*100*0.5=2000                 -1
    // Deleveraged after:    (2000-500)+(-40+10)*100=-1500           1500                     -1
    // Deleverager before:     2000+20*100=4000               20*100*0.5=1000                 4
    // Deleverager after:    (2000+500)+(20-10)*100=3500            1500                      7/3

    let mut spy = snforge_std::spy_events();
    // Test:
    cheat_caller_address_once(contract_address: test_address(), caller_address: cfg.operator);
    state
        .deleverage(
            :operator_nonce,
            deleveraged_position_id: deleveraged.position_id,
            deleverager_position_id: deleverager.position_id,
            deleveraged_base_asset_id: synthetic_id,
            deleveraged_base_amount: BASE,
            deleveraged_quote_asset_id: collateral_id,
            deleveraged_quote_amount: QUOTE,
        );

    // Catch the event.
    let events = spy.get_events().emitted_by(test_address()).events;
    assert_deleverage_event_with_expected(
        spied_event: events[0],
        deleveraged_position_id: deleveraged.position_id,
        deleverager_position_id: deleverager.position_id,
        deleveraged_base_asset_id: synthetic_id,
        deleveraged_base_amount: BASE,
        deleveraged_quote_asset_id: collateral_id,
        deleveraged_quote_amount: QUOTE,
    );

    // Check:
    let deleveraged_position = state
        .positions
        .get_position_snapshot(position_id: deleveraged.position_id);
    let deleverager_position = state
        .positions
        .get_position_snapshot(position_id: deleverager.position_id);

    let deleveraged_collateral_balance = state
        .positions
        .get_provisional_balance(position: deleveraged_position, :collateral_id);
    let deleveraged_synthetic_balance = state
        .positions
        .get_synthetic_balance(position: deleveraged_position, :synthetic_id);
    assert_eq!(deleveraged_collateral_balance, (COLLATERAL_BALANCE_AMOUNT + QUOTE).into());
    assert_eq!(deleveraged_synthetic_balance, (-2 * SYNTHETIC_BALANCE_AMOUNT + BASE).into());

    let deleverager_collateral_balance = state
        .positions
        .get_provisional_balance(position: deleverager_position, :collateral_id);
    let deleverager_synthetic_balance = state
        .positions
        .get_synthetic_balance(position: deleverager_position, :synthetic_id);
    assert_eq!(deleverager_collateral_balance, (COLLATERAL_BALANCE_AMOUNT - QUOTE).into());
    assert_eq!(deleverager_synthetic_balance, (SYNTHETIC_BALANCE_AMOUNT - BASE).into());
}

#[test]
#[should_panic(expected: "POSITION_IS_NOT_FAIR_DELEVERAGE position_id: PositionId { value: 2 }")]
fn test_unfair_deleverage() {
    // Setup state, token and user:
    let cfg: PerpetualsInitConfig = Default::default();
    let token_state = cfg.collateral_cfg.token_cfg.deploy();
    let mut state = setup_state_with_active_asset(cfg: @cfg, token_state: @token_state);

    let deleveraged = Default::default();
    init_position(cfg: @cfg, ref :state, user: deleveraged);
    add_synthetic_to_position(
        ref :state,
        synthetic_id: cfg.synthetic_cfg.synthetic_id,
        position_id: deleveraged.position_id,
        // To make the position deleveragable, the total value must be negative, which requires a
        // negative synthetic balance.
        balance: -2 * SYNTHETIC_BALANCE_AMOUNT,
    );

    let deleverager = UserTrait::new(position_id: POSITION_ID_2, key_pair: KEY_PAIR_2());
    init_position(cfg: @cfg, ref :state, user: deleverager);
    add_synthetic_to_position(
        ref :state,
        synthetic_id: cfg.synthetic_cfg.synthetic_id,
        position_id: deleverager.position_id,
        balance: SYNTHETIC_BALANCE_AMOUNT,
    );

    // Test params:
    let operator_nonce = state.nonce();
    // The following value causes an unfair deleverage, as it breaks the TV/TR ratio.
    let BASE = 10;
    let QUOTE = -10;

    let collateral_id = cfg.collateral_cfg.collateral_id;
    let synthetic_id = cfg.synthetic_cfg.synthetic_id;

    // State change:
    //                            TV                            TR                         TV/TR
    //                COLLATERAL*1 + SYNTHETIC*PRICE        |SYNTHETIC*PRICE*RISK|
    // Deleveraged before:     2000-40*100=-2000              40*100*0.5=2000               -1
    // Deleveraged after:    (2000-10)+(-40+10)*100=-1010           1500                    -101/150
    // Deleverager before:     2000+20*100=4000               20*100*0.5=1000               4
    // Deleverager after:    (2000+10)+(20-10)*100=3010            1500                     301/150

    // Test:
    cheat_caller_address_once(contract_address: test_address(), caller_address: cfg.operator);
    state
        .deleverage(
            :operator_nonce,
            deleveraged_position_id: deleveraged.position_id,
            deleverager_position_id: deleverager.position_id,
            deleveraged_base_asset_id: synthetic_id,
            deleveraged_base_amount: BASE,
            deleveraged_quote_asset_id: collateral_id,
            deleveraged_quote_amount: QUOTE,
        );
}

#[test]
fn test_successful_liquidate() {
    // Setup state, token and user:
    let cfg: PerpetualsInitConfig = Default::default();
    let token_state = cfg.collateral_cfg.token_cfg.deploy();
    let mut state = setup_state_with_active_asset(cfg: @cfg, token_state: @token_state);

    let liquidator = Default::default();
    init_position(cfg: @cfg, ref :state, user: liquidator);
    let liquidated = UserTrait::new(position_id: POSITION_ID_2, key_pair: KEY_PAIR_2());
    init_position(cfg: @cfg, ref :state, user: liquidated);
    add_synthetic_to_position(
        ref :state,
        synthetic_id: cfg.synthetic_cfg.synthetic_id,
        position_id: liquidated.position_id,
        balance: -SYNTHETIC_BALANCE_AMOUNT,
    );

    // Test params:
    let BASE = 10;
    let QUOTE = -5;
    let INSURANCE_FEE = 1;
    let FEE = 2;

    // Setup parameters:
    let expiration = Time::now().add(delta: Time::days(1));
    let operator_nonce = state.nonce();

    let collateral_id = cfg.collateral_cfg.collateral_id;
    let synthetic_id = cfg.synthetic_cfg.synthetic_id;

    let order_liquidator = Order {
        position_id: liquidator.position_id,
        salt: liquidator.salt_counter,
        base_asset_id: synthetic_id,
        base_amount: -BASE,
        quote_asset_id: collateral_id,
        quote_amount: -QUOTE,
        fee_asset_id: collateral_id,
        fee_amount: FEE,
        expiration,
    };

    let liquidator_hash = order_liquidator.get_message_hash(liquidator.get_public_key());
    let liquidator_signature = liquidator.sign_message(liquidator_hash);

    let mut spy = snforge_std::spy_events();
    // Test:
    cheat_caller_address_once(contract_address: test_address(), caller_address: cfg.operator);
    state
        .liquidate(
            :operator_nonce,
            :liquidator_signature,
            liquidated_position_id: liquidated.position_id,
            liquidator_order: order_liquidator,
            actual_amount_base_liquidated: BASE,
            actual_amount_quote_liquidated: QUOTE,
            actual_liquidator_fee: FEE,
            fee_asset_id: collateral_id,
            fee_amount: INSURANCE_FEE,
        );
    // Catch the event.
    let events = spy.get_events().emitted_by(test_address()).events;
    assert_liquidate_event_with_expected(
        spied_event: events[0],
        liquidated_position_id: liquidated.position_id,
        liquidator_order_position_id: liquidator.position_id,
        liquidator_order_base_asset_id: synthetic_id,
        liquidator_order_base_amount: -BASE,
        liquidator_order_quote_asset_id: collateral_id,
        liquidator_order_quote_amount: -QUOTE,
        liquidator_order_fee_asset_id: collateral_id,
        liquidator_order_fee_amount: FEE,
        actual_amount_base_liquidated: BASE,
        actual_amount_quote_liquidated: QUOTE,
        actual_liquidator_fee: FEE,
        insurance_fund_fee_asset_id: collateral_id,
        insurance_fund_fee_amount: INSURANCE_FEE,
        liquidator_order_hash: liquidator_hash,
    );

    // Check:
    let liquidated_position = state
        .positions
        .get_position_snapshot(position_id: liquidated.position_id);
    let liquidator_position = state
        .positions
        .get_position_snapshot(position_id: liquidator.position_id);

    let liquidated_collateral_balance = state
        .positions
        .get_provisional_balance(position: liquidated_position, :collateral_id);
    let liquidated_synthetic_balance = state
        .positions
        .get_synthetic_balance(position: liquidated_position, :synthetic_id);
    assert_eq!(
        liquidated_collateral_balance,
        (COLLATERAL_BALANCE_AMOUNT.into() - INSURANCE_FEE.into() + QUOTE.into()),
    );
    assert_eq!(liquidated_synthetic_balance, (-SYNTHETIC_BALANCE_AMOUNT + BASE).into());

    let liquidator_collateral_balance = state
        .positions
        .get_provisional_balance(position: liquidator_position, :collateral_id);
    let liquidator_synthetic_balance = state
        .positions
        .get_synthetic_balance(position: liquidator_position, :synthetic_id);
    assert_eq!(
        liquidator_collateral_balance,
        (COLLATERAL_BALANCE_AMOUNT.into() - FEE.into() - QUOTE.into()),
    );
    assert_eq!(liquidator_synthetic_balance, (-BASE).into());

    let fee_position = state.positions.get_position_snapshot(position_id: Positions::FEE_POSITION);
    let fee_position_balance = state
        .positions
        .get_provisional_balance(position: fee_position, :collateral_id);
    assert_eq!(fee_position_balance, FEE.into());

    let insurance_fund_position = state
        .positions
        .get_position_snapshot(position_id: Positions::INSURANCE_FUND_POSITION);
    let insurance_position_balance = state
        .positions
        .get_provisional_balance(position: insurance_fund_position, :collateral_id);
    assert_eq!(insurance_position_balance, INSURANCE_FEE.into());
}

// Test set public key.

#[test]
fn test_successful_set_public_key_request() {
    // Setup state, token and user:
    let cfg: PerpetualsInitConfig = Default::default();
    let token_state = cfg.collateral_cfg.token_cfg.deploy();
    let mut state = setup_state_with_active_asset(cfg: @cfg, token_state: @token_state);
    let mut user = Default::default();
    init_position_with_owner(cfg: @cfg, ref :state, :user);

    // Setup parameters:
    let expiration = Time::now().add(delta: Time::days(1));

    let old_public_key = user.get_public_key();
    let new_key_pair = KEY_PAIR_2();
    user.set_public_key(new_key_pair);
    assert_eq!(user.get_public_key(), new_key_pair.public_key);

    // Test change public key in perps:
    cheat_caller_address_once(contract_address: test_address(), caller_address: user.address);
    let set_public_key_args = SetPublicKeyArgs {
        position_id: user.position_id,
        old_public_key,
        new_public_key: user.get_public_key(),
        expiration,
    };
    let msg_hash = set_public_key_args.get_message_hash(public_key: user.get_public_key());
    let signature = user.sign_message(message: msg_hash);
    state
        .set_public_key_request(
            :signature,
            position_id: set_public_key_args.position_id,
            new_public_key: set_public_key_args.new_public_key,
            expiration: set_public_key_args.expiration,
        );

    // Check:
    let status = state.request_approvals.get_request_status(request_hash: msg_hash);
    assert_eq!(status, RequestStatus::PENDING);
}

#[test]
fn test_successful_set_public_key() {
    // Setup state, token and user:
    let cfg: PerpetualsInitConfig = Default::default();
    let token_state = cfg.collateral_cfg.token_cfg.deploy();
    let mut state = setup_state_with_active_asset(cfg: @cfg, token_state: @token_state);
    let mut user = Default::default();
    init_position_with_owner(cfg: @cfg, ref :state, :user);

    // Setup parameters:
    let expiration = Time::now().add(delta: Time::days(1));

    let old_public_key = user.get_public_key();
    let new_key_pair = KEY_PAIR_2();
    user.set_public_key(new_key_pair);
    assert_eq!(user.get_public_key(), new_key_pair.public_key);

    cheat_caller_address_once(contract_address: test_address(), caller_address: user.address);
    let set_public_key_args = SetPublicKeyArgs {
        position_id: user.position_id,
        old_public_key,
        new_public_key: user.get_public_key(),
        expiration,
    };
    let msg_hash = set_public_key_args.get_message_hash(public_key: user.get_public_key());
    let signature = user.sign_message(message: msg_hash);
    let mut spy = snforge_std::spy_events();
    state
        .set_public_key_request(
            :signature,
            position_id: set_public_key_args.position_id,
            new_public_key: set_public_key_args.new_public_key,
            expiration: set_public_key_args.expiration,
        );

    cheat_caller_address_once(contract_address: test_address(), caller_address: cfg.operator);
    state
        .set_public_key(
            operator_nonce: state.nonce(),
            position_id: set_public_key_args.position_id,
            new_public_key: set_public_key_args.new_public_key,
            expiration: set_public_key_args.expiration,
        );

    // Catch the event.
    let events = spy.get_events().emitted_by(test_address()).events;
    assert_set_public_key_request_event_with_expected(
        spied_event: events[0],
        position_id: set_public_key_args.position_id,
        old_public_key: set_public_key_args.old_public_key,
        new_public_key: set_public_key_args.new_public_key,
        expiration: set_public_key_args.expiration,
        set_public_key_request_hash: msg_hash,
    );
    assert_set_public_key_event_with_expected(
        spied_event: events[1],
        position_id: set_public_key_args.position_id,
        old_public_key: set_public_key_args.old_public_key,
        new_public_key: set_public_key_args.new_public_key,
        set_public_key_request_hash: msg_hash,
    );

    // Check:
    assert_eq!(
        user.get_public_key(),
        state
            .positions
            .get_position_snapshot(position_id: user.position_id)
            .owner_public_key
            .read(),
    );
}

#[test]
#[should_panic(expected: 'REQUEST_NOT_REGISTERED')]
fn test_set_public_key_no_request() {
    // Setup state, token and user:
    let cfg: PerpetualsInitConfig = Default::default();
    let token_state = cfg.collateral_cfg.token_cfg.deploy();
    let mut state = setup_state_with_active_asset(cfg: @cfg, token_state: @token_state);
    let mut user = Default::default();
    init_position_with_owner(cfg: @cfg, ref :state, :user);

    // Setup parameters:
    let expiration = Time::now().add(delta: Time::days(1));

    let old_public_key = user.get_public_key();
    let new_key_pair = KEY_PAIR_2();
    user.set_public_key(new_key_pair);

    let set_public_key_args = SetPublicKeyArgs {
        position_id: user.position_id,
        old_public_key,
        new_public_key: user.get_public_key(),
        expiration,
    };
    cheat_caller_address_once(contract_address: test_address(), caller_address: cfg.operator);
    state
        .set_public_key(
            operator_nonce: state.nonce(),
            position_id: set_public_key_args.position_id,
            new_public_key: set_public_key_args.new_public_key,
            expiration: set_public_key_args.expiration,
        );
}

#[test]
#[should_panic(expected: 'CALLER_IS_NOT_OWNER_ACCOUNT')]
fn test_invalid_set_public_key_request_wrong_owner() {
    // Setup state, token and user:
    let cfg: PerpetualsInitConfig = Default::default();
    let token_state = cfg.collateral_cfg.token_cfg.deploy();
    let mut state = setup_state_with_active_asset(cfg: @cfg, token_state: @token_state);
    let no_position_owner = Default::default();
    init_position_with_owner(cfg: @cfg, ref :state, user: no_position_owner);
    let position_owner = UserTrait::new(position_id: POSITION_ID_2, key_pair: KEY_PAIR_2());
    init_position_with_owner(cfg: @cfg, ref :state, user: position_owner);

    // Setup parameters:
    let expiration = Time::now().add(delta: Time::days(1));

    // Test change public key in perps:
    let set_public_key_args = SetPublicKeyArgs {
        position_id: position_owner.position_id,
        old_public_key: position_owner.get_public_key(),
        new_public_key: no_position_owner.get_public_key(),
        expiration,
    };
    let msg_hash = set_public_key_args
        .get_message_hash(public_key: no_position_owner.get_public_key());
    let signature = no_position_owner.sign_message(message: msg_hash);
    cheat_caller_address_once(
        contract_address: test_address(), caller_address: no_position_owner.address,
    );
    state
        .set_public_key_request(
            :signature,
            position_id: set_public_key_args.position_id,
            new_public_key: set_public_key_args.new_public_key,
            expiration: set_public_key_args.expiration,
        );
}

#[test]
#[should_panic(expected: 'POSITION_DOESNT_EXIST')]
fn test_set_public_key_request_position_not_exist() {
    // Setup state, token and user:
    let cfg: PerpetualsInitConfig = Default::default();
    let token_state = cfg.collateral_cfg.token_cfg.deploy();
    let mut state = setup_state_with_active_asset(cfg: @cfg, token_state: @token_state);
    let user: User = Default::default();

    // Setup parameters:
    let expiration = Time::now().add(delta: Time::days(1));
    let set_public_key_args = SetPublicKeyArgs {
        position_id: user.position_id,
        old_public_key: KEY_PAIR_2().public_key,
        new_public_key: user.get_public_key(),
        expiration,
    };

    // Test change public key in perps:
    let msg_hash = set_public_key_args.get_message_hash(public_key: user.get_public_key());
    let signature = user.sign_message(message: msg_hash);

    state
        .set_public_key_request(
            :signature,
            position_id: set_public_key_args.position_id,
            new_public_key: set_public_key_args.new_public_key,
            expiration: set_public_key_args.expiration,
        );
}

// Transfer tests.

#[test]
fn test_successful_transfer_request_using_public_key() {
    // Setup state, token and user:
    let cfg: PerpetualsInitConfig = Default::default();
    let token_state = cfg.collateral_cfg.token_cfg.deploy();
    let mut state = setup_state_with_active_asset(cfg: @cfg, token_state: @token_state);
    let user = Default::default();
    init_position(cfg: @cfg, ref :state, :user);
    let recipient = UserTrait::new(position_id: POSITION_ID_2, key_pair: KEY_PAIR_2());

    // Setup parameters:
    let expected_time = Time::now().add(delta: Time::days(1));
    start_cheat_block_timestamp_global(block_timestamp: expected_time.into());
    let expiration = expected_time.add(delta: Time::days(1));

    let transfer_args = TransferArgs {
        position_id: user.position_id,
        salt: user.salt_counter,
        recipient: recipient.position_id,
        collateral_id: cfg.collateral_cfg.collateral_id,
        amount: TRANSFER_AMOUNT,
        expiration,
    };
    let msg_hash = transfer_args.get_message_hash(public_key: user.get_public_key());
    let signature = user.sign_message(msg_hash);

    // Test:
    cheat_caller_address_once(contract_address: test_address(), caller_address: user.address);
    state
        .transfer_request(
            :signature,
            recipient: transfer_args.recipient,
            position_id: transfer_args.position_id,
            collateral_id: transfer_args.collateral_id,
            amount: transfer_args.amount,
            expiration: transfer_args.expiration,
            salt: transfer_args.salt,
        );

    // Check:
    let status = state.request_approvals.get_request_status(request_hash: msg_hash);
    assert_eq!(status, RequestStatus::PENDING);
}

#[test]
fn test_successful_transfer_request_with_owner() {
    // Setup state, token and user:
    let cfg: PerpetualsInitConfig = Default::default();
    let token_state = cfg.collateral_cfg.token_cfg.deploy();
    let mut state = setup_state_with_active_asset(cfg: @cfg, token_state: @token_state);
    let user = Default::default();
    let recipient = UserTrait::new(position_id: POSITION_ID_2, key_pair: KEY_PAIR_2());
    init_position_with_owner(cfg: @cfg, ref :state, :user);

    // Setup parameters:
    let expected_time = Time::now().add(delta: Time::days(1));
    start_cheat_block_timestamp_global(block_timestamp: expected_time.into());
    let expiration = expected_time.add(delta: Time::days(1));

    let transfer_args = TransferArgs {
        position_id: user.position_id,
        recipient: recipient.position_id,
        salt: user.salt_counter,
        expiration,
        collateral_id: cfg.collateral_cfg.collateral_id,
        amount: TRANSFER_AMOUNT,
    };
    let msg_hash = transfer_args.get_message_hash(public_key: user.get_public_key());
    let signature = user.sign_message(message: msg_hash);

    // Test:
    cheat_caller_address_once(contract_address: test_address(), caller_address: user.address);
    state
        .transfer_request(
            :signature,
            recipient: transfer_args.recipient,
            position_id: transfer_args.position_id,
            collateral_id: transfer_args.collateral_id,
            amount: transfer_args.amount,
            expiration: transfer_args.expiration,
            salt: transfer_args.salt,
        );

    // Check:
    let status = state.request_approvals.get_request_status(request_hash: msg_hash);
    assert_eq!(status, RequestStatus::PENDING);
}

#[test]
fn test_successful_transfer() {
    // Setup state, token and user:
    let cfg: PerpetualsInitConfig = Default::default();
    let token_state = cfg.collateral_cfg.token_cfg.deploy();
    let mut state = setup_state_with_active_asset(cfg: @cfg, token_state: @token_state);

    let sender = Default::default();
    init_position(cfg: @cfg, ref :state, user: sender);

    let recipient = UserTrait::new(position_id: POSITION_ID_2, key_pair: KEY_PAIR_2());
    init_position(cfg: @cfg, ref :state, user: recipient);

    // Setup parameters:
    let expiration = Time::now().add(delta: Time::days(1));
    let collateral_id = cfg.collateral_cfg.collateral_id;
    let operator_nonce = state.nonce();

    let transfer_args = TransferArgs {
        position_id: sender.position_id,
        recipient: recipient.position_id,
        salt: sender.salt_counter,
        expiration: expiration,
        collateral_id,
        amount: TRANSFER_AMOUNT,
    };

    let mut spy = snforge_std::spy_events();
    let msg_hash = transfer_args.get_message_hash(sender.get_public_key());
    let sender_signature = sender.sign_message(msg_hash);
    // Test:
    cheat_caller_address_once(contract_address: test_address(), caller_address: sender.address);
    state
        .transfer_request(
            signature: sender_signature,
            recipient: transfer_args.recipient,
            position_id: transfer_args.position_id,
            collateral_id: transfer_args.collateral_id,
            amount: transfer_args.amount,
            expiration: transfer_args.expiration,
            salt: transfer_args.salt,
        );
    cheat_caller_address_once(contract_address: test_address(), caller_address: cfg.operator);
    state
        .transfer(
            :operator_nonce,
            recipient: transfer_args.recipient,
            position_id: transfer_args.position_id,
            collateral_id: transfer_args.collateral_id,
            amount: transfer_args.amount,
            expiration: transfer_args.expiration,
            salt: transfer_args.salt,
        );

    // Catch the event.
    let events = spy.get_events().emitted_by(test_address()).events;
    assert_transfer_request_event_with_expected(
        spied_event: events[0],
        position_id: transfer_args.position_id,
        recipient: transfer_args.recipient,
        collateral_id: transfer_args.collateral_id,
        amount: transfer_args.amount,
        expiration: transfer_args.expiration,
        transfer_request_hash: msg_hash,
    );
    assert_transfer_event_with_expected(
        spied_event: events[1],
        position_id: transfer_args.position_id,
        recipient: transfer_args.recipient,
        collateral_id: transfer_args.collateral_id,
        amount: transfer_args.amount,
        expiration: transfer_args.expiration,
        transfer_request_hash: msg_hash,
    );

    // Check:
    let sender_position = state.positions.get_position_snapshot(position_id: sender.position_id);
    let sender_collateral_balance = state
        .positions
        .get_provisional_balance(position: sender_position, :collateral_id);
    assert_eq!(
        sender_collateral_balance, COLLATERAL_BALANCE_AMOUNT.into() - TRANSFER_AMOUNT.into(),
    );

    let recipient_position = state
        .positions
        .get_position_snapshot(position_id: recipient.position_id);
    let recipient_collateral_balance = state
        .positions
        .get_provisional_balance(position: recipient_position, :collateral_id);
    assert_eq!(
        recipient_collateral_balance, COLLATERAL_BALANCE_AMOUNT.into() + TRANSFER_AMOUNT.into(),
    );
}

#[test]
#[should_panic(expected: 'INVALID_ZERO_AMOUNT')]
fn test_invalid_transfer_request_amount_is_zero() {
    // Setup state, token and user:
    let cfg: PerpetualsInitConfig = Default::default();
    let token_state = cfg.collateral_cfg.token_cfg.deploy();
    let mut state = setup_state_with_active_asset(cfg: @cfg, token_state: @token_state);

    let sender = Default::default();
    init_position(cfg: @cfg, ref :state, user: sender);

    let recipient = UserTrait::new(position_id: POSITION_ID_2, key_pair: KEY_PAIR_2());
    init_position(cfg: @cfg, ref :state, user: recipient);

    // Setup parameters:
    let expiration = Time::now().add(delta: Time::days(1));
    let collateral_id = cfg.collateral_cfg.collateral_id;

    let transfer_args = TransferArgs {
        position_id: sender.position_id,
        recipient: recipient.position_id,
        salt: sender.salt_counter,
        expiration: expiration,
        collateral_id,
        amount: 0,
    };

    let sender_signature = sender
        .sign_message(transfer_args.get_message_hash(sender.get_public_key()));

    // Test:
    cheat_caller_address_once(contract_address: test_address(), caller_address: sender.address);
    state
        .transfer_request(
            signature: sender_signature,
            recipient: transfer_args.recipient,
            position_id: transfer_args.position_id,
            collateral_id: transfer_args.collateral_id,
            amount: transfer_args.amount,
            expiration: transfer_args.expiration,
            salt: transfer_args.salt,
        );
}

// `validate_synthetic_price` tests.

#[test]
#[should_panic(expected: 'SYNTHETIC_EXPIRED_PRICE')]
fn test_validate_synthetic_prices_expired() {
    // Setup state, token and user:
    let cfg: PerpetualsInitConfig = Default::default();
    let token_state = cfg.collateral_cfg.token_cfg.deploy();
    let mut state = setup_state_with_active_asset(cfg: @cfg, token_state: @token_state);
    let user: User = Default::default();
    init_position(cfg: @cfg, ref :state, :user);
    // Fund user.
    token_state.fund(recipient: user.address, amount: USER_INIT_BALANCE.try_into().unwrap());
    token_state
        .approve(
            owner: user.address,
            spender: test_address(),
            amount: DEPOSIT_AMOUNT.into() * cfg.collateral_cfg.quantum.into(),
        );
    // Set the block timestamp to be after the price validation interval
    let now = Time::now().add(delta: Time::days(count: 2));
    start_cheat_block_timestamp_global(block_timestamp: now.into());
    state.assets.last_funding_tick.write(now);
    cheat_caller_address_once(contract_address: test_address(), caller_address: user.address);
    state
        .deposit(
            beneficiary: user.position_id.into(),
            asset_id: cfg.collateral_cfg.collateral_id.into(),
            quantized_amount: DEPOSIT_AMOUNT.into(),
            salt: user.salt_counter,
        );
    cheat_caller_address_once(contract_address: test_address(), caller_address: cfg.operator);
    // Call the function, should panic with EXPIRED_PRICE error
    state
        .process_deposit(
            operator_nonce: state.nonce(),
            depositor: user.address,
            position_id: user.position_id,
            collateral_id: cfg.collateral_cfg.collateral_id,
            amount: DEPOSIT_AMOUNT,
            salt: user.salt_counter,
        );
}

#[test]
fn test_validate_synthetic_prices_uninitialized_asset() {
    // Setup state, token and user:
    let cfg: PerpetualsInitConfig = Default::default();
    let token_state = cfg.collateral_cfg.token_cfg.deploy();
    let mut state = setup_state_with_pending_asset(cfg: @cfg, token_state: @token_state);
    let user: User = Default::default();
    init_position(cfg: @cfg, ref :state, :user);
    // Fund user.
    token_state.fund(recipient: user.address, amount: USER_INIT_BALANCE.try_into().unwrap());
    token_state
        .approve(
            owner: user.address,
            spender: test_address(),
            amount: DEPOSIT_AMOUNT.into() * cfg.collateral_cfg.quantum.into(),
        );
    let mut synthetic_timely_data = SYNTHETIC_TIMELY_DATA();
    synthetic_timely_data.last_price_update = Time::now();
    state.assets.synthetic_timely_data.write(cfg.synthetic_cfg.synthetic_id, synthetic_timely_data);
    // Set the block timestamp to be after the price validation interval
    let now = Time::now().add(delta: Time::days(count: 2));
    start_cheat_block_timestamp_global(block_timestamp: now.into());
    state.assets.last_funding_tick.write(Time::now());
    cheat_caller_address_once(contract_address: test_address(), caller_address: user.address);
    state
        .deposit(
            beneficiary: user.position_id.into(),
            asset_id: cfg.collateral_cfg.collateral_id.into(),
            quantized_amount: DEPOSIT_AMOUNT.into(),
            salt: user.salt_counter,
        );
    cheat_caller_address_once(contract_address: test_address(), caller_address: cfg.operator);
    // Call the function, should panic with EXPIRED_PRICE error
    state
        .process_deposit(
            operator_nonce: state.nonce(),
            depositor: user.address,
            position_id: user.position_id,
            collateral_id: cfg.collateral_cfg.collateral_id,
            amount: DEPOSIT_AMOUNT,
            salt: user.salt_counter,
        );
    // If no assertion error is thrown, the test passes
}

#[test]
fn test_validate_prices() {
    // Setup state, token and user:
    let cfg: PerpetualsInitConfig = Default::default();
    let token_state = cfg.collateral_cfg.token_cfg.deploy();
    let mut state = setup_state_with_active_asset(cfg: @cfg, token_state: @token_state);
    let user: User = Default::default();
    init_position(cfg: @cfg, ref :state, :user);
    // Fund user.
    token_state.fund(recipient: user.address, amount: USER_INIT_BALANCE.try_into().unwrap());
    token_state
        .approve(
            owner: user.address,
            spender: test_address(),
            amount: DEPOSIT_AMOUNT.into() * cfg.collateral_cfg.quantum.into(),
        );
    let new_time = Time::now().add(delta: Time::days(count: 1));
    start_cheat_block_timestamp_global(block_timestamp: new_time.into());
    state.assets.last_funding_tick.write(Time::now());
    cheat_caller_address_once(contract_address: test_address(), caller_address: user.address);
    state
        .deposit(
            beneficiary: user.position_id.into(),
            asset_id: cfg.collateral_cfg.collateral_id.into(),
            quantized_amount: DEPOSIT_AMOUNT.into(),
            salt: user.salt_counter,
        );
    cheat_caller_address_once(contract_address: test_address(), caller_address: cfg.operator);
    state
        .process_deposit(
            operator_nonce: state.nonce(),
            depositor: user.address,
            position_id: user.position_id,
            collateral_id: cfg.collateral_cfg.collateral_id,
            amount: DEPOSIT_AMOUNT,
            salt: user.salt_counter,
        );
    assert_eq!(state.assets.last_price_validation.read(), new_time);
}

#[test]
fn test_validate_prices_no_update_needed() {
    // Setup state, token and user:
    let cfg: PerpetualsInitConfig = Default::default();
    let token_state = cfg.collateral_cfg.token_cfg.deploy();
    let mut state = setup_state_with_active_asset(cfg: @cfg, token_state: @token_state);
    let user: User = Default::default();
    init_position(cfg: @cfg, ref :state, :user);
    // Fund user.
    token_state.fund(recipient: user.address, amount: USER_INIT_BALANCE.try_into().unwrap());
    token_state
        .approve(
            owner: user.address,
            spender: test_address(),
            amount: DEPOSIT_AMOUNT.into() * cfg.collateral_cfg.quantum.into(),
        );
    let old_time = Time::now();
    assert_eq!(state.assets.last_price_validation.read(), old_time);
    let new_time = Time::now().add(delta: Time::seconds(count: 1000));
    start_cheat_block_timestamp_global(block_timestamp: new_time.into());
    cheat_caller_address_once(contract_address: test_address(), caller_address: user.address);
    state
        .deposit(
            beneficiary: user.position_id.into(),
            asset_id: cfg.collateral_cfg.collateral_id.into(),
            quantized_amount: DEPOSIT_AMOUNT.into(),
            salt: user.salt_counter,
        );
    cheat_caller_address_once(contract_address: test_address(), caller_address: cfg.operator);
    state
        .process_deposit(
            operator_nonce: state.nonce(),
            depositor: user.address,
            position_id: user.position_id,
            collateral_id: cfg.collateral_cfg.collateral_id,
            amount: DEPOSIT_AMOUNT,
            salt: user.salt_counter,
        );

    assert_eq!(state.assets.last_price_validation.read(), old_time);
}

// `funding_tick` tests.

#[test]
fn test_funding_tick_basic() {
    let cfg: PerpetualsInitConfig = Default::default();
    let token_state = cfg.collateral_cfg.token_cfg.deploy();
    let mut state = setup_state_with_active_asset(cfg: @cfg, token_state: @token_state);

    let new_time = Time::now().add(Time::seconds(HOUR));
    start_cheat_block_timestamp_global(block_timestamp: new_time.into());

    let synthetic_id = cfg.synthetic_cfg.synthetic_id;
    // Funding index is 3.
    let new_funding_index = FundingIndex { value: 3 * TWO_POW_32.try_into().unwrap() };
    let funding_ticks: Span<FundingTick> = array![
        FundingTick { asset_id: synthetic_id, funding_index: new_funding_index },
    ]
        .span();

    // Test:

    // The funding index must be within the max funding rate:
    // |prev_funding_index-new_funding_index| = |0 - 3| = 3.
    // synthetic_price * max_funding_rate * time_diff = 100 * 3% per hour * 1 hour = 3.
    // 3 <= 3.
    let mut spy = snforge_std::spy_events();
    cheat_caller_address_once(contract_address: test_address(), caller_address: cfg.operator);
    state.funding_tick(operator_nonce: state.nonce(), :funding_ticks);

    // Catch the event.
    let events = spy.get_events().emitted_by(test_address()).events;
    assert_funding_tick_event_with_expected(
        spied_event: events[0], asset_id: synthetic_id, funding_index: new_funding_index,
    );

    // Check:
    assert_eq!(
        state.assets.get_synthetic_timely_data(synthetic_id).funding_index, new_funding_index,
    );
}

#[test]
#[should_panic(
    expected: "INVALID_FUNDING_RATE synthetic_id: AssetId { value: 720515315941943725751128480342703114962297896757142150278960020243082094068 }",
)]
fn test_invalid_funding_rate() {
    let cfg: PerpetualsInitConfig = Default::default();
    let token_state = cfg.collateral_cfg.token_cfg.deploy();
    let mut state = setup_state_with_active_asset(cfg: @cfg, token_state: @token_state);

    let new_time = Time::now().add(Time::seconds(HOUR));
    start_cheat_block_timestamp_global(block_timestamp: new_time.into());

    let synthetic_id = cfg.synthetic_cfg.synthetic_id;
    // Funding index is 4.
    let new_funding_index = FundingIndex { value: 4 * TWO_POW_32.try_into().unwrap() };
    let funding_ticks: Span<FundingTick> = array![
        FundingTick { asset_id: synthetic_id, funding_index: new_funding_index },
    ]
        .span();

    // Test:

    // The funding index must be within the max funding rate:
    // |prev_funding_index-new_funding_index| = |0 - 4| = 4.
    // synthetic_price * max_funding_rate * time_diff = 100 * 3% per hour * 1 hour = 3.
    // 3 > 4.
    cheat_caller_address_once(contract_address: test_address(), caller_address: cfg.operator);
    state.funding_tick(operator_nonce: state.nonce(), :funding_ticks);
}

#[test]
#[should_panic(expected: 'INVALID_FUNDING_TICK_LEN')]
fn test_invalid_funding_len() {
    let cfg: PerpetualsInitConfig = Default::default();
    let token_state = cfg.collateral_cfg.token_cfg.deploy();
    let mut state = setup_state_with_active_asset(cfg: @cfg, token_state: @token_state);

    let new_time = Time::now().add(Time::seconds(10));
    start_cheat_block_timestamp_global(block_timestamp: new_time.into());

    let new_funding_index_1 = FundingIndex { value: 100 * TWO_POW_32.try_into().unwrap() };
    let new_funding_index_2 = FundingIndex { value: 3 * TWO_POW_32.try_into().unwrap() };
    let funding_ticks: Span<FundingTick> = array![
        FundingTick { asset_id: SYNTHETIC_ASSET_ID_1(), funding_index: new_funding_index_1 },
        FundingTick { asset_id: SYNTHETIC_ASSET_ID_2(), funding_index: new_funding_index_2 },
    ]
        .span();

    // Test:
    cheat_caller_address_once(contract_address: test_address(), caller_address: cfg.operator);
    state.funding_tick(operator_nonce: state.nonce(), :funding_ticks);
}

// `price_tick` tests.

#[test]
fn test_price_tick_basic() {
    let cfg: PerpetualsInitConfig = Default::default();
    let token_state = cfg.collateral_cfg.token_cfg.deploy();
    let mut state = setup_state_with_active_asset(cfg: @cfg, token_state: @token_state);
    let mut spy = snforge_std::spy_events();
    let asset_name = 'ASSET_NAME';
    let oracle1_name = 'ORCL1';
    let oracle1 = Oracle { oracle_name: oracle1_name, asset_name, key_pair: KEY_PAIR_1() };
    let synthetic_id = cfg.synthetic_cfg.synthetic_id;
    cheat_caller_address_once(contract_address: test_address(), caller_address: cfg.app_governor);
    state
        .add_oracle_to_asset(
            asset_id: synthetic_id,
            oracle_public_key: oracle1.key_pair.public_key,
            oracle_name: oracle1_name,
            :asset_name,
        );
    let old_time: u64 = Time::now().into();
    state.assets.synthetic_config.write(synthetic_id, Option::Some(SYNTHETIC_PENDING_CONFIG()));
    state.assets.num_of_active_synthetic_assets.write(Zero::zero());
    assert_eq!(state.assets.get_num_of_active_synthetic_assets(), Zero::zero());
    let new_time = Time::now().add(delta: MAX_ORACLE_PRICE_VALIDITY);
    start_cheat_block_timestamp_global(block_timestamp: new_time.into());
    cheat_caller_address_once(contract_address: test_address(), caller_address: cfg.operator);
    let oracle_price: u128 = TEN_POW_15.into();
    let operator_nonce = state.nonce();
    state
        .price_tick(
            :operator_nonce,
            asset_id: synthetic_id,
            :oracle_price,
            signed_prices: [
                oracle1.get_signed_price(:oracle_price, timestamp: old_time.try_into().unwrap())
            ]
                .span(),
        );

    // Catch the event.
    let events = spy.get_events().emitted_by(test_address()).events;
    assert_add_oracle_event_with_expected(
        spied_event: events[0],
        asset_id: synthetic_id,
        :asset_name,
        oracle_public_key: oracle1.key_pair.public_key,
        oracle_name: oracle1_name,
    );
    assert_asset_activated_event_with_expected(spied_event: events[1], asset_id: synthetic_id);
    assert_price_tick_event_with_expected(
        spied_event: events[2], asset_id: synthetic_id, price: PriceTrait::new(268),
    );

    assert!(state.assets.get_synthetic_config(synthetic_id).status == AssetStatus::ACTIVE);
    assert_eq!(state.assets.get_num_of_active_synthetic_assets(), 1);

    let data = state.assets.get_synthetic_timely_data(synthetic_id);
    assert_eq!(data.last_price_update, new_time);
    assert_eq!(data.price.value(), 268);
}

#[test]
fn test_price_tick_odd() {
    let cfg: PerpetualsInitConfig = Default::default();
    let token_state = cfg.collateral_cfg.token_cfg.deploy();
    let mut state = setup_state_with_active_asset(cfg: @cfg, token_state: @token_state);
    let asset_name = 'ASSET_NAME';
    let oracle1_name = 'ORCL1';
    let oracle2_name = 'ORCL2';
    let oracle3_name = 'ORCL3';
    let oracle1 = Oracle { oracle_name: oracle1_name, asset_name, key_pair: KEY_PAIR_1() };
    let oracle2 = Oracle { oracle_name: oracle2_name, asset_name, key_pair: KEY_PAIR_2() };
    let oracle3 = Oracle { oracle_name: oracle3_name, asset_name, key_pair: KEY_PAIR_3() };
    let synthetic_id = cfg.synthetic_cfg.synthetic_id;
    cheat_caller_address_once(contract_address: test_address(), caller_address: cfg.app_governor);
    state
        .add_oracle_to_asset(
            asset_id: synthetic_id,
            oracle_public_key: oracle1.key_pair.public_key,
            oracle_name: oracle1_name,
            :asset_name,
        );
    cheat_caller_address_once(contract_address: test_address(), caller_address: cfg.app_governor);
    state
        .add_oracle_to_asset(
            asset_id: synthetic_id,
            oracle_public_key: oracle2.key_pair.public_key,
            oracle_name: oracle2_name,
            :asset_name,
        );
    cheat_caller_address_once(contract_address: test_address(), caller_address: cfg.app_governor);
    state
        .add_oracle_to_asset(
            asset_id: synthetic_id,
            oracle_public_key: oracle3.key_pair.public_key,
            oracle_name: oracle3_name,
            :asset_name,
        );
    let old_time: u64 = Time::now().into();
    state.assets.synthetic_config.write(synthetic_id, Option::Some(SYNTHETIC_PENDING_CONFIG()));
    state.assets.num_of_active_synthetic_assets.write(0);
    assert_eq!(state.assets.get_num_of_active_synthetic_assets(), 0);
    let new_time = Time::now().add(delta: MAX_ORACLE_PRICE_VALIDITY);
    start_cheat_block_timestamp_global(block_timestamp: new_time.into());
    cheat_caller_address_once(contract_address: test_address(), caller_address: cfg.operator);
    let oracle_price: u128 = TEN_POW_15.into();
    let operator_nonce = state.nonce();
    state
        .price_tick(
            :operator_nonce,
            asset_id: synthetic_id,
            :oracle_price,
            signed_prices: [
                oracle2.get_signed_price(:oracle_price, timestamp: old_time.try_into().unwrap()),
                oracle3
                    .get_signed_price(
                        oracle_price: oracle_price + 1, timestamp: old_time.try_into().unwrap(),
                    ),
                oracle1
                    .get_signed_price(
                        oracle_price: oracle_price - 1, timestamp: old_time.try_into().unwrap(),
                    ),
            ]
                .span(),
        );
    assert!(state.assets.get_synthetic_config(synthetic_id).status == AssetStatus::ACTIVE);
    assert_eq!(state.assets.get_num_of_active_synthetic_assets(), 1);
    let data = state.assets.get_synthetic_timely_data(synthetic_id);
    assert_eq!(data.last_price_update, new_time);
    assert_eq!(data.price.value(), 268);
}

#[test]
fn test_price_tick_even() {
    let cfg: PerpetualsInitConfig = Default::default();
    let token_state = cfg.collateral_cfg.token_cfg.deploy();
    let mut state = setup_state_with_active_asset(cfg: @cfg, token_state: @token_state);
    let asset_name = 'ASSET_NAME';
    let oracle1_name = 'ORCL1';
    let oracle3_name = 'ORCL3';
    let oracle1 = Oracle { oracle_name: oracle1_name, asset_name, key_pair: KEY_PAIR_1() };
    let oracle3 = Oracle { oracle_name: oracle3_name, asset_name, key_pair: KEY_PAIR_3() };
    let synthetic_id = cfg.synthetic_cfg.synthetic_id;
    cheat_caller_address_once(contract_address: test_address(), caller_address: cfg.app_governor);
    state
        .add_oracle_to_asset(
            asset_id: synthetic_id,
            oracle_public_key: oracle1.key_pair.public_key,
            oracle_name: oracle1_name,
            :asset_name,
        );
    cheat_caller_address_once(contract_address: test_address(), caller_address: cfg.app_governor);
    state
        .add_oracle_to_asset(
            asset_id: synthetic_id,
            oracle_public_key: oracle3.key_pair.public_key,
            oracle_name: oracle3_name,
            :asset_name,
        );
    let old_time: u64 = Time::now().into();
    state.assets.synthetic_config.write(synthetic_id, Option::Some(SYNTHETIC_PENDING_CONFIG()));
    state.assets.num_of_active_synthetic_assets.write(0);
    assert_eq!(state.assets.get_num_of_active_synthetic_assets(), 0);
    let new_time = Time::now().add(delta: MAX_ORACLE_PRICE_VALIDITY);
    start_cheat_block_timestamp_global(block_timestamp: new_time.into());
    cheat_caller_address_once(contract_address: test_address(), caller_address: cfg.operator);
    let oracle_price: u128 = TEN_POW_15.into();
    let operator_nonce = state.nonce();
    state
        .price_tick(
            :operator_nonce,
            asset_id: synthetic_id,
            :oracle_price,
            signed_prices: [
                oracle3
                    .get_signed_price(
                        oracle_price: oracle_price + 1, timestamp: old_time.try_into().unwrap(),
                    ),
                oracle1
                    .get_signed_price(
                        oracle_price: oracle_price - 1, timestamp: old_time.try_into().unwrap(),
                    ),
            ]
                .span(),
        );
    assert!(state.assets.get_synthetic_config(synthetic_id).status == AssetStatus::ACTIVE);
    assert_eq!(state.assets.get_num_of_active_synthetic_assets(), 1);

    let data = state.assets.get_synthetic_timely_data(synthetic_id);
    assert_eq!(data.last_price_update, new_time);
    assert_eq!(data.price.value(), 268);
}

#[test]
#[should_panic(expected: 'QUORUM_NOT_REACHED')]
fn test_price_tick_no_quorum() {
    let cfg: PerpetualsInitConfig = Default::default();
    let token_state = cfg.collateral_cfg.token_cfg.deploy();
    let mut state = setup_state_with_active_asset(cfg: @cfg, token_state: @token_state);
    cheat_caller_address_once(contract_address: test_address(), caller_address: cfg.operator);
    let operator_nonce = state.nonce();
    state
        .price_tick(
            :operator_nonce,
            asset_id: cfg.synthetic_cfg.synthetic_id,
            oracle_price: Zero::zero(),
            signed_prices: [].span(),
        );
}

#[test]
#[should_panic(expected: 'SIGNED_PRICES_UNSORTED')]
fn test_price_tick_unsorted() {
    let cfg: PerpetualsInitConfig = Default::default();
    let token_state = cfg.collateral_cfg.token_cfg.deploy();
    let mut state = setup_state_with_active_asset(cfg: @cfg, token_state: @token_state);
    let asset_name = 'ASSET_NAME';
    let oracle1_name = 'ORCL1';
    let oracle2_name = 'ORCL2';
    let oracle1 = Oracle { oracle_name: oracle1_name, asset_name, key_pair: KEY_PAIR_1() };
    let oracle2 = Oracle { oracle_name: oracle2_name, asset_name, key_pair: KEY_PAIR_3() };
    let synthetic_id = cfg.synthetic_cfg.synthetic_id;
    cheat_caller_address_once(contract_address: test_address(), caller_address: cfg.app_governor);
    state
        .add_oracle_to_asset(
            asset_id: synthetic_id,
            oracle_public_key: oracle1.key_pair.public_key,
            oracle_name: oracle1_name,
            :asset_name,
        );
    cheat_caller_address_once(contract_address: test_address(), caller_address: cfg.app_governor);
    state
        .add_oracle_to_asset(
            asset_id: synthetic_id,
            oracle_public_key: oracle2.key_pair.public_key,
            oracle_name: oracle2_name,
            :asset_name,
        );
    let old_time: u64 = Time::now().into();
    state.assets.synthetic_config.write(synthetic_id, Option::Some(SYNTHETIC_PENDING_CONFIG()));
    cheat_caller_address_once(contract_address: test_address(), caller_address: cfg.operator);
    let oracle_price: u128 = TEN_POW_15.into();
    let operator_nonce = state.nonce();
    state
        .price_tick(
            :operator_nonce,
            asset_id: synthetic_id,
            :oracle_price,
            signed_prices: [
                oracle1
                    .get_signed_price(
                        oracle_price: oracle_price - 1, timestamp: old_time.try_into().unwrap(),
                    ),
                oracle2
                    .get_signed_price(
                        oracle_price: oracle_price + 1, timestamp: old_time.try_into().unwrap(),
                    ),
            ]
                .span(),
        );
}

#[test]
#[should_panic(expected: 'INVALID_PRICE_TIMESTAMP')]
fn test_price_tick_old_oracle() {
    let cfg: PerpetualsInitConfig = Default::default();
    let token_state = cfg.collateral_cfg.token_cfg.deploy();
    let mut state = setup_state_with_active_asset(cfg: @cfg, token_state: @token_state);
    let asset_name = 'ASSET_NAME';
    let oracle1_name = 'ORCL1';
    let oracle1 = Oracle { oracle_name: oracle1_name, asset_name, key_pair: KEY_PAIR_1() };
    let synthetic_id = cfg.synthetic_cfg.synthetic_id;
    cheat_caller_address_once(contract_address: test_address(), caller_address: cfg.app_governor);
    state
        .add_oracle_to_asset(
            asset_id: synthetic_id,
            oracle_public_key: oracle1.key_pair.public_key,
            oracle_name: oracle1_name,
            :asset_name,
        );
    let old_time: u64 = Time::now().into();
    let new_time = Time::now().add(delta: MAX_ORACLE_PRICE_VALIDITY + Time::seconds(1));
    start_cheat_block_timestamp_global(block_timestamp: new_time.into());
    cheat_caller_address_once(contract_address: test_address(), caller_address: cfg.operator);
    let oracle_price = 1000;
    let operator_nonce = state.nonce();
    state
        .price_tick(
            :operator_nonce,
            asset_id: synthetic_id,
            :oracle_price,
            signed_prices: [
                oracle1.get_signed_price(:oracle_price, timestamp: old_time.try_into().unwrap())
            ]
                .span(),
        );
}

#[test]
/// This test numbers were taken from an example of a real price tick that was sent to StarkEx.
fn test_price_tick_golden() {
    let cfg: PerpetualsInitConfig = Default::default();
    let token_state = cfg.collateral_cfg.token_cfg.deploy();
    let mut state = setup_state_with_active_asset(cfg: @cfg, token_state: @token_state);
    let asset_name = 'PENGUUSDMARK\x00\x00\x00\x00';
    let oracle0_name = 'Stkai';
    let oracle1_name = 'Stork';
    let oracle2_name = 'StCrw';
    let synthetic_id = cfg.synthetic_cfg.synthetic_id;
    cheat_caller_address_once(contract_address: test_address(), caller_address: cfg.app_governor);
    state
        .add_oracle_to_asset(
            asset_id: synthetic_id,
            oracle_public_key: 0x1f191d23b8825dcc3dba839b6a7155ea07ad0b42af76394097786aca0d9975c,
            oracle_name: oracle0_name,
            :asset_name,
        );
    cheat_caller_address_once(contract_address: test_address(), caller_address: cfg.app_governor);
    state
        .add_oracle_to_asset(
            asset_id: synthetic_id,
            oracle_public_key: 0xcc85afe4ca87f9628370c432c447e569a01dc96d160015c8039959db8521c4,
            oracle_name: oracle1_name,
            :asset_name,
        );
    cheat_caller_address_once(contract_address: test_address(), caller_address: cfg.app_governor);
    state
        .add_oracle_to_asset(
            asset_id: synthetic_id,
            oracle_public_key: 0x41dbe627aeab66504b837b3abd88ae2f58ba6d98ee7bbd7f226c4684d9e6225,
            oracle_name: oracle2_name,
            :asset_name,
        );

    let timestamp: u32 = 1737451956;
    let oracle_price = 23953641840000000;
    let signed_price0 = SignedPrice {
        signature: [
            0x23120d436ab1e115f883fd495206b80c9a9928f94df89c2bb63eb1997cc13d5,
            0x21469ce0da02bf1a5897077b238f536f78427f946dafde2b79884cf10131e74,
        ]
            .span(),
        signer_public_key: 0x1f191d23b8825dcc3dba839b6a7155ea07ad0b42af76394097786aca0d9975c,
        timestamp,
        oracle_price,
    };
    let signed_price1 = SignedPrice {
        signature: [
            0x6c4beab13946105513c157ca8498735af2c3ff0f75efe6e1d1747efcff8339f,
            0x94619200c9b03a647f6f29df52d2291e866b43e57dc1a8200deb5219c87b14,
        ]
            .span(),
        signer_public_key: 0xcc85afe4ca87f9628370c432c447e569a01dc96d160015c8039959db8521c4,
        timestamp,
        oracle_price,
    };
    let signed_price2 = SignedPrice {
        signature: [
            0x3aed46d0aff9d904faf5f76c2fb9f43c858e6f9e9c9bf99ca9fd4c1baa907b2,
            0x58523be606a55c57aedd5e030a349a478a22132b84d6f77e1e348a4991f5c80,
        ]
            .span(),
        signer_public_key: 0x41dbe627aeab66504b837b3abd88ae2f58ba6d98ee7bbd7f226c4684d9e6225,
        timestamp,
        oracle_price,
    };
    start_cheat_block_timestamp_global(
        block_timestamp: Timestamp { seconds: timestamp.into() + 1 }.into(),
    );
    cheat_caller_address_once(contract_address: test_address(), caller_address: cfg.operator);
    let operator_nonce = state.nonce();
    state
        .price_tick(
            :operator_nonce,
            asset_id: synthetic_id,
            :oracle_price,
            signed_prices: [signed_price1, signed_price0, signed_price2].span(),
        );
    let data = state.assets.get_synthetic_timely_data(synthetic_id);
    assert_eq!(data.last_price_update, Time::now());
    assert_eq!(data.price.value(), 6430);
}

// Add and remove oracle tests.

#[test]
fn test_successful_add_and_remove_oracle() {
    let cfg: PerpetualsInitConfig = Default::default();
    let token_state = cfg.collateral_cfg.token_cfg.deploy();
    let mut state = setup_state_with_active_asset(cfg: @cfg, token_state: @token_state);

    let asset_name = 'ASSET_NAME';
    let oracle_name = 'ORCL';
    let key_pair = KEY_PAIR_1();
    // let oracle1 = Oracle { oracle_name, asset_name, key_pair };
    let synthetic_id = cfg.synthetic_cfg.synthetic_id;

    // Test:
    let mut spy = snforge_std::spy_events();
    cheat_caller_address_once(contract_address: test_address(), caller_address: cfg.app_governor);
    state
        .add_oracle_to_asset(
            asset_id: synthetic_id,
            oracle_public_key: key_pair.public_key,
            :oracle_name,
            :asset_name,
        );

    // Add another oracle for the same asset id.
    let asset_name = 'ASSET_NAME';
    let oracle_name = 'ORCL';
    let key_pair = KEY_PAIR_2();
    cheat_caller_address_once(contract_address: test_address(), caller_address: cfg.app_governor);
    state
        .add_oracle_to_asset(
            asset_id: synthetic_id,
            oracle_public_key: key_pair.public_key,
            :oracle_name,
            :asset_name,
        );

    state.remove_oracle_from_asset(asset_id: synthetic_id, oracle_public_key: key_pair.public_key);

    let events = spy.get_events().emitted_by(test_address()).events;
    assert_add_oracle_event_with_expected(
        spied_event: events[1],
        asset_id: synthetic_id,
        :asset_name,
        oracle_public_key: key_pair.public_key,
        :oracle_name,
    );
    assert_remove_oracle_event_with_expected(
        spied_event: events[2], asset_id: synthetic_id, oracle_public_key: key_pair.public_key,
    );
}

#[test]
#[should_panic(expected: 'ORACLE_NAME_TOO_LONG')]
fn test_add_oracle_name_too_long() {
    let cfg: PerpetualsInitConfig = Default::default();
    let token_state = cfg.collateral_cfg.token_cfg.deploy();
    let mut state = setup_state_with_active_asset(cfg: @cfg, token_state: @token_state);

    let asset_name = 'ASSET_NAME';
    let oracle_name = 'LONG_ORACLE_NAME';
    let key_pair = KEY_PAIR_1();
    let synthetic_id = cfg.synthetic_cfg.synthetic_id;

    // Test:
    cheat_caller_address_once(contract_address: test_address(), caller_address: cfg.app_governor);
    state
        .add_oracle_to_asset(
            asset_id: synthetic_id,
            oracle_public_key: key_pair.public_key,
            :oracle_name,
            :asset_name,
        );
}

#[test]
#[should_panic(expected: 'ASSET_NAME_TOO_LONG')]
fn test_add_oracle_asset_name_too_long() {
    let cfg: PerpetualsInitConfig = Default::default();
    let token_state = cfg.collateral_cfg.token_cfg.deploy();
    let mut state = setup_state_with_active_asset(cfg: @cfg, token_state: @token_state);

    let asset_name = 'TOO_LONG_ASSET_NAME';
    let oracle_name = 'ORCL';
    let key_pair = KEY_PAIR_1();
    let synthetic_id = cfg.synthetic_cfg.synthetic_id;

    // Test:
    cheat_caller_address_once(contract_address: test_address(), caller_address: cfg.app_governor);
    state
        .add_oracle_to_asset(
            asset_id: synthetic_id,
            oracle_public_key: key_pair.public_key,
            :oracle_name,
            :asset_name,
        );
}

#[test]
#[should_panic(expected: 'ORACLE_ALREADY_EXISTS')]
fn test_add_existed_oracle() {
    let cfg: PerpetualsInitConfig = Default::default();
    let token_state = cfg.collateral_cfg.token_cfg.deploy();
    let mut state = setup_state_with_active_asset(cfg: @cfg, token_state: @token_state);

    let asset_name = 'ASSET_NAME';
    let oracle_name = 'ORCL';
    let key_pair = KEY_PAIR_1();
    let synthetic_id = cfg.synthetic_cfg.synthetic_id;

    // Test:
    cheat_caller_address_once(contract_address: test_address(), caller_address: cfg.app_governor);
    state
        .add_oracle_to_asset(
            asset_id: synthetic_id,
            oracle_public_key: key_pair.public_key,
            :oracle_name,
            :asset_name,
        );

    // Add the a new oracle with the same names, and different public key.
    let asset_name = 'SAME_ASSET_NAME';
    let oracle_name = 'ORCL2';

    cheat_caller_address_once(contract_address: test_address(), caller_address: cfg.app_governor);
    state
        .add_oracle_to_asset(
            asset_id: synthetic_id,
            oracle_public_key: key_pair.public_key,
            :oracle_name,
            :asset_name,
        );
}

#[test]
#[should_panic(expected: 'ORACLE_NOT_EXISTS')]
fn test_successful_remove_nonexistent_oracle() {
    let cfg: PerpetualsInitConfig = Default::default();
    let token_state = cfg.collateral_cfg.token_cfg.deploy();
    let mut state = setup_state_with_active_asset(cfg: @cfg, token_state: @token_state);

    // Parameters:
    let key_pair = KEY_PAIR_1();
    let synthetic_id = cfg.synthetic_cfg.synthetic_id;

    // Test:
    cheat_caller_address_once(contract_address: test_address(), caller_address: cfg.app_governor);
    state.remove_oracle_from_asset(asset_id: synthetic_id, oracle_public_key: key_pair.public_key);
}

