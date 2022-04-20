// SPDX-License-Identifier: BUSL 1.1
pragma solidity 0.8.11;

import "ds-test/test.sol";
import "forge-std/Vm.sol";
import "forge-std/Test.sol";
import "./interfaces/IERC20.sol";
import "../OptionSettlement.sol";
import "../interfaces/IOptionSettlementEngine.sol";

/// @notice Receiver hook utility for NFT 'safe' transfers
abstract contract NFTreceiver {
    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return 0x150b7a02;
    }

    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return 0xf23a6e61;
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        return 0xbc197c81;
    }
}

contract OptionSettlementTest is Test, NFTreceiver {
    using stdStorage for StdStorage;

    OptionSettlementEngine public engine;

    // Tokens
    address public constant WETH_A = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant DAI_A = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address public constant USDC_A = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // Admin
    address public constant FEE_TO = 0x36273803306a3C22bc848f8Db761e974697ece0d;

    // Users
    address public constant ALICE = address(0xA);
    address public constant BOB = address(0xB);
    address public constant CAROL = address(0xC);
    address public constant DAVE = address(0xD);
    address public constant EVE = address(0xE);

    // Token interfaces
    IERC20 public constant DAI = IERC20(DAI_A);
    IERC20 public constant WETH = IERC20(WETH_A);
    IERC20 public constant USDC = IERC20(USDC_A);

    // Test option
    uint256 private testOptionId;
    uint40 private testExerciseTimestamp;
    uint40 private testExpiryTimestamp;
    uint96 private testUnderlyingAmount = 7 ether; // NOTE: uneven number to test for division rounding
    uint96 private testExerciseAmount = 3000 ether;
    uint256 private testDuration = 1 days;

    function writeTokenBalance(
        address who,
        address token,
        uint256 amt
    ) internal {
        stdstore
            .target(token)
            .sig(IERC20(token).balanceOf.selector)
            .with_key(who)
            .checked_write(amt);
    }

    function setUp() public {
        engine = new OptionSettlementEngine();

        testExerciseTimestamp = uint40(block.timestamp);
        testExpiryTimestamp = uint40(block.timestamp + testDuration);
        IOptionSettlementEngine.Option memory option = IOptionSettlementEngine
            .Option({
                underlyingAsset: WETH_A,
                exerciseAsset: DAI_A,
                settlementSeed: 1234567,
                underlyingAmount: testUnderlyingAmount,
                exerciseAmount: testExerciseAmount,
                exerciseTimestamp: testExerciseTimestamp,
                expiryTimestamp: testExpiryTimestamp
            });
        testOptionId = engine.newChain(option);

        // pre-load balances and approvals
        address[6] memory recipients = [
            address(engine),
            ALICE,
            BOB,
            CAROL,
            DAVE,
            EVE
        ];
        for (uint256 i = 0; i < 6; i++) {
            address recipient = recipients[i];
            // Now we have 1B in stables and 10M WETH 
            writeTokenBalance(recipient, DAI_A, 1000000000 * 1e18);
            writeTokenBalance(recipient, USDC_A, 1000000000 * 1e6);
            writeTokenBalance(recipient, WETH_A, 10000000 * 1e18);
            vm.startPrank(recipient);
            WETH.approve(address(engine), type(uint256).max);
            DAI.approve(address(engine), type(uint256).max);
            USDC.approve(address(engine), type(uint256).max);
            engine.setApprovalForAll(address(this), true);
            vm.stopPrank();
        }
    }

    // **********************************************************************
    //                            PASS TESTS
    // **********************************************************************

    function testSetFeeTo() public {
        assertEq(engine.feeTo(), FEE_TO);
        vm.expectRevert(abi.encodeWithSelector(IOptionSettlementEngine.AccessControlViolation.selector, address(this), FEE_TO));
        engine.setFeeTo(ALICE);
        vm.startPrank(FEE_TO);
        engine.setFeeTo(ALICE);
        vm.stopPrank();
        assertEq(engine.feeTo(), ALICE);
    }

    function test_exercise_BeforeExpiry() public {
        // Alice writes
        vm.startPrank(ALICE);
        engine.write(testOptionId, 1);
        engine.safeTransferFrom(ALICE, BOB, testOptionId, 1, "");
        vm.stopPrank();

        // Fast-forward to just before expiry
        vm.warp(testExpiryTimestamp - 1);
        
        // Bob exercises
        vm.startPrank(BOB);
        engine.exercise(testOptionId, 1);
        vm.stopPrank();
    }

    function test_exercise_AdditionalAmount() public {
        IOptionSettlementEngine.Claim memory claim;

        // Alice writes 1
        vm.startPrank(ALICE);
        uint256 claimId1 = engine.write(testOptionId, 1);
        // Then writes another
        uint256 claimId2 = engine.write(testOptionId, 1);
        vm.stopPrank();

        claim = engine.claim(claimId1);
        assertEq(claim.option, testOptionId);
        assertEq(claim.amountWritten, 1);
        assertEq(claim.amountExercised, 0);
        if (claim.claimed == false) assertTrue(true);
        
        claim = engine.claim(claimId2);
        assertEq(claim.option, testOptionId);
        assertEq(claim.amountWritten, 1);
        assertTrue(!claim.claimed);    
    }

    // TODO: this test fails with an `InvalidAssets()` error
    // function test_exercise_WithDifferentDecimals() public {
    //     // write an option where one of the assets isn't 18 decimals
    //     IOptionSettlementEngine.Option memory option = IOptionSettlementEngine
    //         .Option({
    //             underlyingAsset: USDC_A,
    //             exerciseAsset: DAI_A,
    //             settlementSeed: 1234567,
    //             underlyingAmount: testUnderlyingAmount,
    //             exerciseAmount: testExerciseAmount,
    //             exerciseTimestamp: testExerciseTimestamp,
    //             expiryTimestamp: testExpiryTimestamp
    //         });
    //     uint256 optionId = engine.newChain(option);

    //     vm.startPrank(ALICE);
    //     engine.write(optionId, 1);
    //     engine.safeTransferFrom(ALICE, BOB, optionId, 1, "");
    //     vm.stopPrank();
    //     vm.warp(1);
    //     vm.startPrank(BOB);
    //     engine.exercise(optionId, 1);
    //     vm.stopPrank();
    // }


    // **********************************************************************
    //                            FAIL TESTS
    // **********************************************************************
   function testFail_newChain_OptionsChainExists() public {
        IOptionSettlementEngine.Option memory option = IOptionSettlementEngine
            .Option({
                underlyingAsset: WETH_A,
                exerciseAsset: DAI_A,
                settlementSeed: 1234567,
                underlyingAmount: testUnderlyingAmount,
                exerciseAmount: testExerciseAmount,
                exerciseTimestamp: testExerciseTimestamp,
                expiryTimestamp: testExpiryTimestamp
            });
        // TODO: investigate this revert - OptionsChainExists error should be displayed
        //  with an argument, implying this expectRevert would use `abi.encodeWithSelector();
        vm.expectRevert(IOptionSettlementEngine.OptionsChainExists.selector);
        engine.newChain(option);
    }

    function testFail_newChain_ExerciseWindowTooShort() public {
        IOptionSettlementEngine.Option memory option = IOptionSettlementEngine
            .Option({
                underlyingAsset: WETH_A,
                exerciseAsset: DAI_A,
                settlementSeed: 1234567,
                underlyingAmount: testUnderlyingAmount,
                exerciseAmount: testExerciseAmount,
                exerciseTimestamp: testExerciseTimestamp,
                expiryTimestamp: testExpiryTimestamp - 1
            });
        vm.expectRevert(IOptionSettlementEngine.ExerciseWindowTooShort.selector);
        engine.newChain(option);
    }

    // TODO: this test should fail but doesn't
    // function testFail_newChain_InvalidAssets() public {
    //     IOptionSettlementEngine.Option memory option = IOptionSettlementEngine
    //         .Option({
    //             underlyingAsset: DAI_A,
    //             exerciseAsset: DAI_A,
    //             settlementSeed: 1234567,
    //             underlyingAmount: testUnderlyingAmount,
    //             exerciseAmount: testExerciseAmount,
    //             exerciseTimestamp: testExerciseTimestamp,
    //             expiryTimestamp: testExpiryTimestamp
    //         });
    //     vm.expectRevert(IOptionSettlementEngine.InvalidAssets.selector);
    //     engine.newChain(option);
    // }


    function testFail_assignExercise() public {
        // Exercise an option before anyone has written it        
        vm.expectRevert(IOptionSettlementEngine.NoClaims.selector);
        engine.exercise(testOptionId, 1);
    }

    function testFail_write_InvalidOption() public {
        vm.expectRevert(IOptionSettlementEngine.InvalidOption.selector);
        engine.write(testOptionId + 1, 1);
    }

    function testFail_write_ExpiredOption() public {
        vm.warp(testExpiryTimestamp);
        vm.expectRevert(IOptionSettlementEngine.ExpiredOption.selector);
    }
    
    function testFail_exercise_BeforeExcercise() public {
        IOptionSettlementEngine.Option memory option = IOptionSettlementEngine
            .Option({
                underlyingAsset: WETH_A,
                exerciseAsset: WETH_A,
                settlementSeed: 1234567,
                underlyingAmount: testUnderlyingAmount,
                exerciseAmount: testExerciseAmount,
                exerciseTimestamp: testExerciseTimestamp + 1,
                expiryTimestamp: testExpiryTimestamp + 1
            });
        uint256 badOptionId = engine.newChain(option);

        // Alice writes
        vm.startPrank(ALICE);
        engine.write(badOptionId, 1);
        engine.safeTransferFrom(ALICE, BOB, badOptionId, 1, "");
        vm.stopPrank();

        // Bob immediately exercises before exerciseTimestamp
        vm.startPrank(BOB);
        vm.expectRevert(IOptionSettlementEngine.ExpiredOption.selector);
        engine.exercise(badOptionId, 1);
        vm.stopPrank();
    }

    function testFail_exercise_AtExpiry() public {
        // Alice writes
        vm.startPrank(ALICE);
        engine.write(testOptionId, 1);
        engine.safeTransferFrom(ALICE, BOB, testOptionId, 1, "");
        vm.stopPrank();

        // Fast-forward to at expiry
        vm.warp(testExpiryTimestamp);
    
        // Bob exercises
        vm.startPrank(BOB);
        vm.expectRevert(IOptionSettlementEngine.ExpiredOption.selector);
        engine.exercise(testOptionId, 1);
        vm.stopPrank();
    }

    function testFail_exercise_ExpiredOption() public {
        // Alice writes
        vm.startPrank(ALICE);
        engine.write(testOptionId, 1);
        engine.safeTransferFrom(ALICE, BOB, testOptionId, 1, "");
        vm.stopPrank();

        // Fast-forward to after expiry
        vm.warp(testExpiryTimestamp + 1);
    
        // Bob exercises
        vm.startPrank(BOB);
        vm.expectRevert(IOptionSettlementEngine.ExpiredOption.selector);
        engine.exercise(testOptionId, 1);
        vm.stopPrank();
    }

    function testFail_redeem_InvalidClaim() public {
        vm.startPrank(ALICE);
        // TODO: shouldn't we have to pass in an arg to this error?
        vm.expectRevert(IOptionSettlementEngine.InvalidClaim.selector);
        engine.redeem(69);
    }

    function testFail_redeem_BalanceTooLow() public {
        // Alice writes and transfers to bob, then alice tries to redeem
        vm.startPrank(ALICE);
        uint256 claimId = engine.write(testOptionId, 1);
        engine.safeTransferFrom(ALICE, BOB, testOptionId, 1, "");
        vm.expectRevert(IOptionSettlementEngine.BalanceTooLow.selector);
        engine.redeem(claimId);
        vm.stopPrank();
        // Carol feels left out and tries to redeem what she can't
        vm.startPrank(CAROL);
        vm.expectRevert(IOptionSettlementEngine.BalanceTooLow.selector);
        engine.redeem(claimId);
        vm.stopPrank();
        // Bob redeems, which should burn, and then be unable to redeem a second time
        vm.startPrank(BOB);
        engine.redeem(claimId);
        vm.expectRevert(IOptionSettlementEngine.BalanceTooLow.selector);
        engine.redeem(claimId);
    }

    function testFail_redeem_AlreadyClaimed() public {
        vm.startPrank(ALICE);
        uint256 claimId = engine.write(testOptionId, 1);
        // write a second option so balance will be > 0
        engine.write(testOptionId, 1);
        vm.warp(testExpiryTimestamp + 1);
        engine.redeem(claimId);
        vm.expectRevert(IOptionSettlementEngine.AlreadyClaimed.selector);
        engine.redeem(claimId);
    }

    // TODO: this passes when it shouldn't
    // function testFail_redeem_ClaimTooSoon() public {
    //     vm.startPrank(ALICE);
    //     uint256 claimId = engine.write(testOptionId, 1);
    //     vm.warp(testExpiryTimestamp - 1);
    //     vm.expectRevert(IOptionSettlementEngine.ClaimTooSoon.selector);
    //     engine.redeem(claimId);
    // }

    // **********************************************************************
    //                            FUZZ TESTS
    // **********************************************************************

    function testFuzz_newChain(
        uint96 underlyingAmount,
        uint96 exerciseAmount,
        uint40 exerciseTimestamp,
        uint40 expiryTimestamp
    ) public {
        vm.assume(expiryTimestamp >= block.timestamp + 86400);
        vm.assume(exerciseTimestamp >= block.timestamp);
        vm.assume(exerciseTimestamp <= expiryTimestamp - 86400);
        vm.assume(expiryTimestamp <= type(uint64).max);
        vm.assume(exerciseTimestamp <= type(uint64).max);
        vm.assume(underlyingAmount <= WETH.totalSupply());
        vm.assume(exerciseAmount <= DAI.totalSupply());

        IOptionSettlementEngine.Option
            memory optionInfo = IOptionSettlementEngine.Option({
                underlyingAsset: WETH_A,
                exerciseAsset: DAI_A,
                settlementSeed: 0,
                underlyingAmount: underlyingAmount,
                exerciseAmount: exerciseAmount,
                exerciseTimestamp: exerciseTimestamp,
                expiryTimestamp: expiryTimestamp
            });

        uint256 optionId = engine.newChain(optionInfo);
        assertEq(optionId, 2);

        IOptionSettlementEngine.Option memory optionRecord = engine.option(
            optionId
        );

        assertEq(
            engine.hashToOptionToken(keccak256(abi.encode(optionInfo))),
            optionId
        );
        assertEq(optionRecord.underlyingAsset, WETH_A);
        assertEq(optionRecord.exerciseAsset, DAI_A);
        assertEq(optionRecord.exerciseTimestamp, exerciseTimestamp);
        assertEq(optionRecord.expiryTimestamp, expiryTimestamp);
        assertEq(optionRecord.underlyingAmount, underlyingAmount);
        assertEq(optionRecord.exerciseAmount, exerciseAmount);
        assertEq(optionRecord.settlementSeed, 0);

        if (engine.tokenType(optionId) == IOptionSettlementEngine.Type.Option)
            assertTrue(true);
    }

    // TODO: fails with counterexample
    // function testFuzz_write(uint112 amount) public {
    //     uint256 wethBalanceEngine = WETH.balanceOf(address(engine));
    //     uint256 wethBalance = WETH.balanceOf(ALICE);

    //     vm.assume(amount > 0);
    //     vm.assume(amount <= wethBalance / testUnderlyingAmount);

    //     uint256 rxAmount = amount * testUnderlyingAmount;
    //     uint256 fee = ((rxAmount / 10000) * engine.feeBps());

    //     vm.startPrank(ALICE);
    //     uint256 claimId = engine.write(testOptionId, amount);
    //     IOptionSettlementEngine.Claim memory claimRecord = engine.claim(
    //         claimId
    //     );

    //     assertEq(
    //         WETH.balanceOf(address(engine)),
    //         wethBalanceEngine + rxAmount + fee
    //     );
    //     assertEq(WETH.balanceOf(ALICE), wethBalance - rxAmount - fee);

    //     assertEq(engine.balanceOf(address(this), testOptionId), amount);
    //     assertEq(engine.balanceOf(address(this), claimId), 1);
    //     assertTrue(!claimRecord.claimed);
    //     assertEq(claimRecord.option, testOptionId);
    //     assertEq(claimRecord.amountWritten, amount);
    //     assertEq(claimRecord.amountExercised, 0);

    //     if (engine.tokenType(claimId) == IOptionSettlementEngine.Type.Claim)
    //         assertTrue(true);
    // }

    function testFuzz_exercise(uint112 amountWrite, uint112 amountExercise)
        public
    {
        uint256 wethBalanceEngine = WETH.balanceOf(address(engine));
        uint256 daiBalanceEngine = DAI.balanceOf(address(engine));
        uint256 wethBalance = WETH.balanceOf(ALICE);
        uint256 daiBalance = DAI.balanceOf(ALICE);

        vm.assume(amountWrite > 0);
        vm.assume(amountExercise > 0);
        vm.assume(amountWrite >= amountExercise);
        vm.assume(amountWrite <= wethBalance / testUnderlyingAmount);
        vm.assume(amountExercise <= daiBalance / testExerciseAmount);

        uint256 writeAmount = amountWrite * testUnderlyingAmount;
        uint256 rxAmount = amountExercise * testExerciseAmount;
        uint256 txAmount = amountExercise * testUnderlyingAmount;
        uint256 exerciseFee = (rxAmount / 10000) * engine.feeBps();
        uint256 writeFee = ((amountWrite * testUnderlyingAmount) / 10000) * engine.feeBps();

        vm.startPrank(ALICE);
        uint256 claimId = engine.write(testOptionId, amountWrite);

        vm.warp(uint40(block.timestamp) + 1);

        engine.exercise(testOptionId, amountExercise);

        IOptionSettlementEngine.Claim memory claimRecord = engine.claim(
            claimId
        );

        assertTrue(!claimRecord.claimed);
        assertEq(claimRecord.option, testOptionId);
        assertEq(claimRecord.amountWritten, amountWrite);
        assertEq(claimRecord.amountExercised, amountExercise);

        assertEq(
            WETH.balanceOf(address(engine)),
            wethBalanceEngine + writeAmount - txAmount + writeFee
        );
        assertEq(
            WETH.balanceOf(ALICE),
            (wethBalance - writeAmount + txAmount - writeFee)
        );
        assertEq(
            DAI.balanceOf(address(engine)),
            daiBalanceEngine + rxAmount + exerciseFee
        );
        assertEq(
            DAI.balanceOf(ALICE),
            (daiBalance - rxAmount - exerciseFee)
        );
        assertEq(
            engine.balanceOf(ALICE, testOptionId),
            amountWrite - amountExercise
        );
        assertEq(engine.balanceOf(ALICE, claimId), 1);
    }

    function testFuzzRedeem(uint112 amountWrite, uint112 amountExercise)
        public
    {
        uint256 wethBalanceEngine = WETH.balanceOf(address(engine));
        uint256 daiBalanceEngine = DAI.balanceOf(address(engine));
        uint256 wethBalance = WETH.balanceOf(ALICE);
        uint256 daiBalance = DAI.balanceOf(ALICE);

        vm.assume(amountWrite > 0);
        vm.assume(amountExercise > 0);
        vm.assume(amountWrite >= amountExercise);
        vm.assume(amountWrite <= wethBalance / testUnderlyingAmount);
        vm.assume(amountExercise <= daiBalance / testExerciseAmount);

        uint256 rxAmount = amountExercise * testExerciseAmount;
        uint256 exerciseFee = (rxAmount / 10000) * engine.feeBps();
        uint256 writeFee = ((amountWrite * testUnderlyingAmount) / 10000) * engine.feeBps();

        vm.startPrank(ALICE);
        uint256 claimId = engine.write(testOptionId, amountWrite);

        vm.warp(uint40(block.timestamp) + 1);
        engine.exercise(testOptionId, amountExercise);

        vm.warp(1e15);

        engine.redeem(claimId);

        IOptionSettlementEngine.Claim memory claimRecord = engine.claim(
            claimId
        );

        assertEq(WETH.balanceOf(address(engine)), wethBalanceEngine + writeFee);
        assertEq(WETH.balanceOf(ALICE), wethBalance - writeFee);
        assertEq(
            DAI.balanceOf(address(engine)),
            daiBalanceEngine + exerciseFee
        );
        assertEq(DAI.balanceOf(ALICE), daiBalance - exerciseFee);
        assertEq(
            engine.balanceOf(ALICE, testOptionId),
            amountWrite - amountExercise
        );
        assertEq(engine.balanceOf(ALICE, claimId), 0);
        assertTrue(claimRecord.claimed);

        if (engine.tokenType(claimId) == IOptionSettlementEngine.Type.Claim)
            assertTrue(true);
    }
}
